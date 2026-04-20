# backtick_javascript: true
# await: true
# Cloudflare Workers runtime adapter for Opal.
#
# This file is the only place in the homurabi codebase that knows the
# underlying transport is Cloudflare Workers. Its job is to make CF Workers
# look like any other Rack server (Puma, Unicorn, Falcon, WEBrick, ...).
# User Ruby code is therefore a plain Rack application and would run
# unchanged on any Rack-compatible host.
#
# Three responsibilities, modelled after existing Ruby conventions:
#
#   1. CloudflareWorkersIO — replaces nodejs.rb's $stdout / $stderr (which
#      try to write to a closed Socket on Workers) with shims that route
#      Ruby `puts` / `print` to V8's globalThis.console.log/error.
#
#   2. Rack::Handler::CloudflareWorkers — a standard Rack handler. Same
#      shape as Rack::Handler::Puma, Rack::Handler::WEBrick, etc. User
#      code uses the conventional top-level `run app` from a config.ru-
#      style entry point and never sees a Cloudflare-specific symbol.
#
#   3. Cloudflare::D1Database / KVNamespace / R2Bucket — tiny Ruby wrappers
#      around the JS bindings. They expose the binding methods as regular
#      Ruby method calls returning native JS Promises, which the user
#      routes can `.__await__` inside a `# await: true` block.
#
# Note: Opal Strings are immutable (they map to JS Strings), so this file
# uses reassignment (`@buffer = @buffer + str`) instead of `<<` mutation.

require 'stringio'
require 'await'

# ---------------------------------------------------------------------------
# 1. stdout / stderr → console.log / console.error
# ---------------------------------------------------------------------------

class CloudflareWorkersIO
  def initialize(channel)
    @channel = channel  # 'log' or 'error'
    @buffer = ''
  end

  def write(*args)
    written = 0
    args.each do |arg|
      str = arg.to_s
      @buffer = @buffer + str
      written += str.length
    end
    flush_lines
    written
  end

  def puts(*args)
    if args.empty?
      emit('')
      return nil
    end
    args.each do |arg|
      if arg.is_a?(Array)
        puts(*arg)
        next
      end
      line = arg.to_s
      @buffer = @buffer + (line.end_with?("\n") ? line : line + "\n")
    end
    flush_lines
    nil
  end

  def print(*args)
    args.each { |a| @buffer = @buffer + a.to_s }
    flush_lines
    nil
  end

  def flush
    return self if @buffer.empty?
    emit(@buffer)
    @buffer = ''
    self
  end

  def sync; true; end
  def sync=(_); end
  def tty?; false; end
  def isatty; false; end
  def closed?; false; end

  private

  def flush_lines
    while (idx = @buffer.index("\n"))
      line = @buffer[0...idx]
      @buffer = @buffer[(idx + 1)..-1] || ''
      emit(line)
    end
  end

  def emit(line)
    channel = @channel
    text = line
    `globalThis.console[#{channel}](#{text})`
  end
end

$stdout = CloudflareWorkersIO.new('log')
$stderr = CloudflareWorkersIO.new('error')
Object.const_set(:STDOUT, $stdout) unless Object.const_defined?(:STDOUT) && STDOUT.is_a?(CloudflareWorkersIO)
Object.const_set(:STDERR, $stderr) unless Object.const_defined?(:STDERR) && STDERR.is_a?(CloudflareWorkersIO)

# ---------------------------------------------------------------------------
# 2. Rack::Handler::CloudflareWorkers
# ---------------------------------------------------------------------------
#
# Conforms to the Rack handler convention: a module with a `run` class
# method that takes a Rack app, registers it, and arranges for incoming
# requests to be dispatched through it. See Rack::Handler::Puma,
# Rack::Handler::WEBrick, etc. for prior art.

module Rack
  module Handler
    module CloudflareWorkers
      EMPTY_STRING_IO = StringIO.new('').freeze

      def self.run(app, **_options)
        @app = app
        install_dispatcher
        app
      end

      def self.app
        @app
      end

      # Entry point invoked from the Module Worker (src/worker.mjs) for
      # every fetch event. `js_req` is a Cloudflare Workers Request,
      # `js_env` is the bindings object (D1, KV, R2, secrets...),
      # `js_ctx` is the ExecutionContext, `body_text` is the pre-resolved
      # request body (the worker.mjs front awaits req.text() before
      # handing control to Ruby because Opal runs synchronously).
      def self.call(js_req, js_env, js_ctx, body_text = '')
        raise '`run app` was never called from user code' if @app.nil?

        env = build_rack_env(js_req, js_env, js_ctx, body_text)
        status, headers, body = @app.call(env)
        build_js_response(status, headers, body)
      ensure
        body.close if body.respond_to?(:close) && body
      end

      class << self
        private

        def install_dispatcher
          handler = self
          `
            globalThis.__HOMURABI_RACK_DISPATCH__ = async function(req, env, ctx, body_text) {
              return await #{handler}.$call(req, env, ctx, body_text == null ? "" : body_text);
            };
            (function () {
              var g = globalThis;
              g.__OPAL_WORKERS__ = g.__OPAL_WORKERS__ || {};
              g.__OPAL_WORKERS__.rack = g.__HOMURABI_RACK_DISPATCH__;
            })();
          `
        end

        # Build a Rack-compliant env Hash from a Cloudflare Workers Request.
        # See https://github.com/rack/rack/blob/main/SPEC.rdoc for the contract.
        def build_rack_env(js_req, js_env, js_ctx, body_text = '')
          method  = `#{js_req}.method`
          url_obj = `new URL(#{js_req}.url)`
          path    = `#{url_obj}.pathname`
          raw_qs  = `#{url_obj}.search`  # includes leading '?' or empty string
          qs      = raw_qs && raw_qs.length > 0 ? raw_qs[1..-1] : ''
          scheme  = `#{url_obj}.protocol`.sub(/:\z/, '')
          host    = `#{url_obj}.hostname`
          port    = `#{url_obj}.port`
          port    = (scheme == 'https' ? '443' : '80') if port.nil? || port.empty?

          env = {
            'REQUEST_METHOD'    => method,
            'SCRIPT_NAME'       => '',
            'PATH_INFO'         => path,
            'QUERY_STRING'      => qs,
            'SERVER_NAME'       => host,
            'SERVER_PORT'       => port,
            'SERVER_PROTOCOL'   => 'HTTP/1.1',
            'HTTPS'             => scheme == 'https' ? 'on' : 'off',
            'rack.url_scheme'   => scheme,
            'rack.input'        => body_text.nil? || body_text.empty? ? EMPTY_STRING_IO : StringIO.new(body_text),
            'rack.errors'       => $stderr,
            'rack.multithread'  => false,
            'rack.multiprocess' => false,
            'rack.run_once'     => false,
            'rack.hijack?'      => false,
          }

          copy_headers_into_env(js_req, env)

          # Cloudflare-specific extras under their own namespace, per the
          # Rack convention that env keys other than the standard ones
          # SHOULD use a `<library>.<key>` form.
          env['cloudflare.env'] = js_env
          env['cloudflare.ctx'] = js_ctx

          # Expose D1 / KV / R2 bindings as plain Ruby wrapper objects.
          # The user Sinatra routes reach them via
          # `env['cloudflare.DB']` / `.KV` / `.BUCKET`, call normal-looking
          # Ruby methods on them, and `.__await__` the resulting JS Promise.
          js_db = `#{js_env} && #{js_env}.DB`
          js_kv = `#{js_env} && #{js_env}.KV`
          js_r2 = `#{js_env} && #{js_env}.BUCKET`
          js_ai = `#{js_env} && #{js_env}.AI`
          env['cloudflare.DB']     = Cloudflare::D1Database.new(js_db)  if `#{js_db} != null`
          env['cloudflare.KV']     = Cloudflare::KVNamespace.new(js_kv) if `#{js_kv} != null`
          env['cloudflare.BUCKET'] = Cloudflare::R2Bucket.new(js_r2)    if `#{js_r2} != null`
          # Phase 10: env.AI is a Workers AI binding object. Routes call
          # Cloudflare::AI.run(model, inputs, binding: env['cloudflare.AI'])
          # to invoke a model. We expose the raw JS object (not a wrapper)
          # because the wrapper is stateless — every call passes both the
          # model id and the binding explicitly.
          env['cloudflare.AI']     = js_ai if `#{js_ai} != null`

          # Phase 11B: Durable Objects / Queues.
          # env.COUNTER is a DurableObjectNamespace binding; wrap it into
          # Cloudflare::DurableObjectNamespace so routes can call
          # `do_counter.get_by_name("global").fetch('/inc').__await__`
          # without a backtick. env.JOBS_QUEUE is a Queue producer binding.
          js_do_counter = `#{js_env} && #{js_env}.COUNTER`
          if `#{js_do_counter} != null`
            env['cloudflare.DO_COUNTER'] = Cloudflare::DurableObjectNamespace.new(js_do_counter)
          end
          js_queue = `#{js_env} && #{js_env}.JOBS_QUEUE`
          env['cloudflare.QUEUE_JOBS'] = Cloudflare::Queue.new(js_queue, 'JOBS_QUEUE') if `#{js_queue} != null`
          js_dlq = `#{js_env} && #{js_env}.JOBS_DLQ`
          env['cloudflare.QUEUE_JOBS_DLQ'] = Cloudflare::Queue.new(js_dlq, 'JOBS_DLQ') if `#{js_dlq} != null`

          env
        end

        # Copy CF Workers Request headers into Rack HTTP_* keys, with the
        # spec-mandated CONTENT_TYPE / CONTENT_LENGTH special cases.
        def copy_headers_into_env(js_req, env)
          ruby_env = env
          `
            #{js_req}.headers.forEach(function(value, key) {
              var lower = key.toLowerCase();
              var rack_key;
              if (lower === "content-type") {
                rack_key = "CONTENT_TYPE";
              } else if (lower === "content-length") {
                rack_key = "CONTENT_LENGTH";
              } else {
                rack_key = "HTTP_" + key.toUpperCase().replace(/-/g, "_");
              }
              #{ruby_env}.$store(rack_key, value);
            })
          `
        end

        # Convert a Rack response triple [status, headers, body] into a
        # Cloudflare Workers Response. `body` must respond to #each yielding
        # strings, per the Rack body contract. Arrays satisfy this.
        #
        # Chunks can also be JS Promises (returned by D1 / KV / R2 binding
        # wrappers). When any chunk is a thenable, we return a JS Promise
        # that awaits all of them, concatenates their results into a body
        # string, and resolves to a fresh Response. worker.mjs awaits the
        # value we return, so both sync and async paths look the same on
        # the outside.
        def build_js_response(status, headers, body)
          # Raw JS Response fast-path (Phase 11B): a route that needs
          # to hand the Workers runtime a Response object that was
          # constructed OUTSIDE our pipeline (e.g. a 101 upgrade
          # Response carrying a `.webSocket` property from a DO
          # stub.fetch) wraps it in Cloudflare::RawResponse. We pass
          # the JS object through unchanged — any reconstruction
          # would strip runtime-only properties the client depends on.
          raw = nil
          if body.is_a?(::Cloudflare::RawResponse)
            raw = body
          elsif body.respond_to?(:first) && body.first.is_a?(::Cloudflare::RawResponse)
            raw = body.first
          end
          if raw
            js_resp = raw.js_response
            return js_resp
          end

          # Binary body fast-path: pass the JS ReadableStream directly
          # to Response without touching Opal's String encoding.
          if body.is_a?(::Cloudflare::BinaryBody) || (body.respond_to?(:first) && body.first.is_a?(::Cloudflare::BinaryBody))
            bin = body.is_a?(::Cloudflare::BinaryBody) ? body : body.first
            js_stream = bin.stream
            ct = bin.content_type
            cc = bin.cache_control
            js_headers = `({})`
            headers.each { |k, v| ks = k.to_s; vs = v.to_s; `#{js_headers}[#{ks}] = #{vs}` }
            `#{js_headers}['content-type'] = #{ct}` if ct
            `#{js_headers}['cache-control'] = #{cc}` if cc
            return `new Response(#{js_stream}, { status: #{status.to_i}, headers: #{js_headers} })`
          end

          # Phase 10 — Workers AI streaming: a Cloudflare::AI::Stream wraps
          # a JS ReadableStream<Uint8Array> emitting SSE-formatted bytes
          # ("data: {json}\n\n"). Pass it straight through so the client
          # receives the chunks as they arrive.
          stream_obj = nil
          if body.respond_to?(:sse_stream?) && body.sse_stream?
            stream_obj = body
          elsif body.respond_to?(:first) && body.first.respond_to?(:sse_stream?) && body.first.sse_stream?
            stream_obj = body.first
          end
          if stream_obj
            js_stream = stream_obj.js_stream
            js_headers = `({})`
            # Order: Rack-response headers → stream-provided headers
            # (SSE defaults + caller extras) → route-set hard wins. The
            # old code hardcoded text/event-stream here, which silently
            # dropped any `headers:` hash the caller passed to `sse`.
            # Merge the stream's own response_headers if it exposes them
            # (duck-type; non-SSE stream wrappers may not).
            headers.each { |k, v| ks = k.to_s; vs = v.to_s; `#{js_headers}[#{ks}] = #{vs}` }
            if stream_obj.respond_to?(:response_headers)
              stream_obj.response_headers.each { |k, v| ks = k.to_s; vs = v.to_s; `#{js_headers}[#{ks}] = #{vs}` }
            else
              # Legacy Cloudflare::AI::Stream (Phase 10.3) doesn't expose
              # response_headers; keep the hardcoded SSE defaults for
              # backwards compatibility in that case.
              `#{js_headers}['content-type'] = 'text/event-stream; charset=utf-8'`
              `#{js_headers}['cache-control'] = 'no-cache, no-transform'`
              `#{js_headers}['x-accel-buffering'] = 'no'`
            end
            return `new Response(#{js_stream}, { status: #{status.to_i}, headers: #{js_headers} })`
          end

          chunks = []
          if body.respond_to?(:each)
            body.each { |chunk| chunks << chunk }
          else
            chunks << body
          end

          js_headers = `({})`
          headers.each do |k, v|
            ks = k.to_s
            vs = v.to_s
            `#{js_headers}[#{ks}] = #{vs}`
          end

          status_int = status.to_i

          js_chunks = `[]`
          has_promise = false
          chunks.each do |c|
            `#{js_chunks}.push(#{c})`
            has_promise = true if `#{c} != null && typeof #{c}.then === 'function'`
          end

          if has_promise
            # Phase 10 patch: route may return [status, body] from a
            # post-await branch so it can express a non-200 status the
            # async-promise path of Sinatra::Base#invoke would otherwise
            # snapshot away. Single-line x-string per the file convention.
            #
            # Phase 11B addendum: if any resolved chunk is a
            # `Cloudflare::RawResponse` (`.$$is_raw_response` on the
            # Opal side OR has `js_response` + `raw_response?` duck
            # markers), return its underlying JS Response verbatim —
            # used for 101 WebSocket upgrades where the Workers
            # runtime's own Response carries runtime-only properties
            # (`.webSocket`) that a reconstructed Response would lose.
            `Promise.all(#{js_chunks}).then(function(resolved) { for (var i = 0; i < resolved.length; i++) { var r = resolved[i]; if (r != null && typeof r === 'object' && typeof r['$raw_response?'] === 'function' && typeof r['$js_response'] === 'function') { try { if (r['$raw_response?']()) { return r['$js_response'](); } } catch (_) {} } } for (var i = 0; i < resolved.length; i++) { var r = resolved[i]; if (r != null && r.stream != null && r.content_type != null) { var bh = {}; bh['content-type'] = r.content_type; if (r.cache_control) bh['cache-control'] = r.cache_control; return new Response(r.stream, { status: #{status_int}, headers: bh }); } } if (resolved.length === 1 && resolved[0] != null && Array.isArray(resolved[0]) && resolved[0].length === 2 && typeof resolved[0][0] === 'number') { var ov = resolved[0]; var ovs = ov[0]|0; var ovb = ov[1] == null ? '' : (typeof ov[1] === 'string' ? ov[1] : (ov[1].$$is_string ? ov[1].toString() : String(ov[1]))); return new Response(ovb, { status: ovs, headers: #{js_headers} }); } var parts = []; for (var i = 0; i < resolved.length; i++) { var r = resolved[i]; if (r == null) { parts.push(''); continue; } if (typeof r === 'string') { parts.push(r); continue; } if (r != null && r.$$is_string) { parts.push(r.toString()); continue; } try { parts.push(JSON.stringify(r)); } catch (e) { parts.push(String(r)); } } return new Response(parts.join(''), { status: #{status_int}, headers: #{js_headers} }); })`
          else
            body_str = ''
            chunks.each { |c| body_str = body_str + c.to_s }
            `new Response(#{body_str}, { status: #{status_int}, headers: #{js_headers} })`
          end
        end
      end
    end
  end
end

# ---------------------------------------------------------------------------
# 3. Top-level `run` so user code looks like config.ru
# ---------------------------------------------------------------------------
#
# Rack::Builder normally provides `run` inside a config.ru file. Since
# our user .rb files are not literal config.ru, we install `run` on
# Kernel as a private method so it is callable from any top-level Ruby
# scope without leaking through method_missing or polluting Object's
# public surface.

# ---------------------------------------------------------------------------
# 3. Top-level `run` so user code looks like config.ru
# ---------------------------------------------------------------------------
module Kernel
  private

  def run(app, **options)
    Rack::Handler::CloudflareWorkers.run(app, **options)
  end
end

# ---------------------------------------------------------------------------
# 4. Cloudflare bindings — D1 / KV / R2 wrappers
# ---------------------------------------------------------------------------
#
# These wrappers give Sinatra routes a plain Ruby API over the underlying
# Cloudflare JS objects. Each mutation method (D1 `.all`/`.first`/`.run`,
# KV `.get`/`.put`/`.delete`, R2 `.get`/`.put`) returns a raw JS Promise
# that user code is expected to `.__await__` inside a `# await: true`
# route block.
#
# The wrappers convert incoming Ruby values to JS and outgoing JS values
# to Ruby where it matters (D1 row hashes, KV strings, R2 object bodies),
# so user code never has to reach for a backtick.

module Cloudflare
  # Base error class for Cloudflare binding failures. Wraps the JS
  # error message so Ruby rescue can handle it meaningfully.
  class BindingError < StandardError
    attr_reader :binding_type, :operation

    def initialize(message, binding_type: nil, operation: nil)
      @binding_type = binding_type
      @operation = operation
      super("[Cloudflare::#{binding_type}] #{operation}: #{message}")
    end
  end

  class D1Error < BindingError; end
  class KVError < BindingError; end
  class R2Error < BindingError; end

  # Check whether the argument is a native JS Promise / thenable.
  # Ruby's `Object#then` (alias of `yield_self`) is a universal method
  # since Ruby 2.6, so `obj.respond_to?(:then)` is always true and is
  # useless as a Promise detector. We must check for a JS function
  # at `.then` instead.
  def self.js_promise?(obj)
    `(#{obj} != null && typeof #{obj}.then === 'function' && typeof #{obj}.catch === 'function')`
  end

  # JS Array -> Ruby Array of Ruby Hashes (for D1 result.results).
  def self.js_rows_to_ruby(js_rows)
    out = []
    return out if `#{js_rows} == null`
    len = `#{js_rows}.length`
    i = 0
    while i < len
      js_row = `#{js_rows}[#{i}]`
      out << js_object_to_hash(js_row)
      i += 1
    end
    out
  end

  # Shallow copy of a JS object's own enumerable string keys into a Hash.
  def self.js_object_to_hash(js_obj)
    h = {}
    return h if `#{js_obj} == null`
    keys = `Object.keys(#{js_obj})`
    len  = `#{keys}.length`
    i = 0
    while i < len
      k = `#{keys}[#{i}]`
      v = `#{js_obj}[#{k}]`
      h[k] = v
      i += 1
    end
    h
  end

  # RawResponse wraps an already-constructed JS `Response` so routes
  # can return it through Sinatra and have `build_js_response` pass
  # it through to the Workers runtime untouched. Needed when the
  # Response carries runtime-only properties that would disappear if
  # reconstructed — e.g. a 101 upgrade Response with `.webSocket`.
  # Unlike `BinaryBody`, no new Response is constructed; the stored
  # JS object is returned as-is.
  class RawResponse
    attr_reader :js_response

    def initialize(js_response)
      @js_response = js_response
    end

    # Rack body contract — yield nothing. The bytes never flow
    # through Ruby; the JS Response goes straight to the runtime.
    def each; end

    def close; end

    def raw_response?
      true
    end
  end

  # BinaryBody wraps a JS ReadableStream (from R2, fetch, etc.) so it can
  # flow through the Rack/Sinatra body pipeline without being converted to
  # an Opal String (which would mangle the bytes). `build_js_response`
  # detects BinaryBody and passes the stream directly to `new Response`.
  class BinaryBody
    attr_reader :stream, :content_type, :cache_control

    def initialize(stream, content_type = 'application/octet-stream', cache_control = nil)
      @stream = stream
      @content_type = content_type
      @cache_control = cache_control
    end

    # Rack body contract — yield nothing so Sinatra's content-length
    # calculation skips this body. The real bytes go through JS.
    def each; end

    def close; end
  end

  # NOTE: the single-line backtick `...` form is used below instead of the
  # multi-line `%x{ ... }` or multi-line backtick form. Opal's compiler
  # treats a *multi-line* x-string as a raw statement and refuses to use
  # it as an expression — which would silently return `undefined` from a
  # wrapper method. Keeping each x-string on one line makes Opal emit it
  # as a true expression that the surrounding Ruby code can return.

  # D1Database wraps a Cloudflare D1 JS binding. The public API is
  # modelled on CRuby's `sqlite3-ruby` gem (`SQLite3::Database`) so
  # that the calling code reads identically:
  #
  #     # sqlite3-ruby on CRuby:
  #     rows = db.execute("SELECT * FROM users WHERE id = ?", [1])
  #
  #     # homurabi on Opal (+ async):
  #     rows = db.execute("SELECT * FROM users WHERE id = ?", [1]).__await__
  #
  # Every query method returns a JS Promise. Use `.__await__` inside a
  # `# await: true` route block to unwrap it synchronously (Opal
  # compiles `.__await__` to a native JS `await`).
  #
  # Results are always Hashes — `results_as_hash` is effectively
  # hardcoded to `true`. This matches the common `db.results_as_hash =
  # true` convention in the sqlite3-ruby world and gives downstream ORM
  # code a ready-made Hash-per-row interface to build on.
  class D1Database
    def initialize(js)
      @js = js
    end

    # ---- sqlite3-ruby compatible high-level API ----------------------

    # Execute a SQL statement with optional bind parameters and return
    # all result rows as an Array of Hashes.
    #
    #   db.execute("SELECT * FROM users")                           → Array<Hash>
    #   db.execute("SELECT * FROM users WHERE id = ?", [1])         → Array<Hash>
    #   db.execute("INSERT INTO users (name) VALUES (?)", ["alice"]) → Array<Hash> (empty for writes)
    def execute(sql, bind_params = [])
      stmt = prepare(sql)
      stmt = stmt.bind(*bind_params) unless bind_params.empty?
      stmt.all
    end

    # Execute and return only the first row (or nil).
    #
    #   db.get_first_row("SELECT * FROM users WHERE id = ?", [1])  → Hash or nil
    def get_first_row(sql, bind_params = [])
      stmt = prepare(sql)
      stmt = stmt.bind(*bind_params) unless bind_params.empty?
      stmt.first
    end

    # Execute a write statement (INSERT / UPDATE / DELETE) and return
    # a metadata Hash with `changes`, `last_row_id`, `duration`, etc.
    #
    #   meta = db.execute_insert("INSERT INTO users (name) VALUES (?)", ["alice"])
    #   meta['last_row_id']  # → 7
    def execute_insert(sql, bind_params = [])
      stmt = prepare(sql)
      stmt = stmt.bind(*bind_params) unless bind_params.empty?
      stmt.run
    end

    # Execute one or more raw SQL statements separated by semicolons.
    # Useful for schema migrations. Returns the D1 exec result.
    def execute_batch(sql)
      exec(sql)
    end

    # ---- low-level D1 API (prepare/bind/all/first/run) ---------------

    def prepare(sql)
      js = @js
      D1Statement.new(`#{js}.prepare(#{sql})`)
    end

    def exec(sql)
      js = @js
      `(#{js}.exec ? #{js}.exec(#{sql}) : #{js}.prepare(#{sql}).run())`
    end
  end

  class D1Statement
    def initialize(js)
      @js = js
    end

    def bind(*args)
      js_args = `[]`
      args.each { |a| `#{js_args}.push(#{a})` }
      js = @js
      D1Statement.new(`#{js}.bind.apply(#{js}, #{js_args})`)
    end

    # Returns a JS Promise that resolves to a Ruby Array of Ruby Hashes.
    def all
      js_stmt = @js
      cf = Cloudflare
      err_cls = Cloudflare::D1Error
      `#{js_stmt}.all().then(function(res) { return #{cf}.$js_rows_to_ruby(res.results); }).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'D1', operation: 'all'}))); })`
    end

    # Returns a JS Promise that resolves to a single Ruby Hash (or nil).
    def first
      js_stmt = @js
      cf = Cloudflare
      err_cls = Cloudflare::D1Error
      `#{js_stmt}.first().then(function(res) { return res == null ? nil : #{cf}.$js_object_to_hash(res); }).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'D1', operation: 'first'}))); })`
    end

    # Returns a JS Promise that resolves to a Ruby Hash with the D1 meta.
    def run
      js_stmt = @js
      cf = Cloudflare
      err_cls = Cloudflare::D1Error
      `#{js_stmt}.run().then(function(res) { return #{cf}.$js_object_to_hash(res); }).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'D1', operation: 'run'}))); })`
    end
  end

  class KVNamespace
    def initialize(js)
      @js = js
    end

    # KV#get returns a JS Promise resolving to a String or nil.
    def get(key)
      js_kv = @js
      err_cls = Cloudflare::KVError
      `#{js_kv}.get(#{key}, "text").then(function(v) { return v == null ? nil : v; }).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'KV', operation: 'get'}))); })`
    end

    # Put a value. `expiration_ttl:` (seconds) maps to the Workers KV
    # `expirationTtl` option so callers can set TTLs without reaching
    # for backticks. Returns a JS Promise.
    def put(key, value, expiration_ttl: nil)
      js_kv = @js
      err_cls = Cloudflare::KVError
      ttl = expiration_ttl
      if ttl.nil?
        `#{js_kv}.put(#{key}, #{value}).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'KV', operation: 'put'}))); })`
      else
        ttl_int = ttl.to_i
        `#{js_kv}.put(#{key}, #{value}, { expirationTtl: #{ttl_int} }).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'KV', operation: 'put'}))); })`
      end
    end

    # Delete a key. Returns a JS Promise.
    def delete(key)
      js_kv = @js
      err_cls = Cloudflare::KVError
      `#{js_kv}.delete(#{key}).catch(function(e) { #{Kernel}.$raise(#{err_cls}.$new(e.message || String(e), Opal.hash({binding_type: 'KV', operation: 'delete'}))); })`
    end
  end

  class R2Bucket
    def initialize(js)
      @js = js
    end

    # R2 get. Returns a JS Promise resolving to a Ruby Hash (or nil).
    def get(key)
      js_bucket = @js
      fallback_key = key
      `#{js_bucket}.get(#{key}).then(async function(obj) { if (obj == null) return nil; var text = await obj.text(); var rb = new Map(); rb.set('body', text); rb.set('etag', obj.etag || ''); rb.set('size', obj.size || 0); rb.set('key', obj.key || #{fallback_key}); return rb; })`
    end

    # R2 get_binary. Returns a JS Promise that resolves to a
    # Cloudflare::BinaryBody (wrapping the R2 object's ReadableStream)
    # or nil. Use this for serving images and other binary content
    # through Sinatra routes without byte-mangling.
    #
    #   get '/images/:key' do
    #     obj = bucket.get_binary(key).__await__
    #     halt 404 if obj.nil?
    #     obj  # BinaryBody flows through build_js_response as a stream
    #   end
    # Returns a JS Promise resolving to a Cloudflare::BinaryBody or nil.
    # BinaryBody wraps the R2 ReadableStream so build_js_response can
    # pass it straight to `new Response(stream)` without mangling bytes.
    def get_binary(key)
      js_bucket = @js
      bb = Cloudflare::BinaryBody
      `#{js_bucket}.get(#{key}).then(function(obj) { if (obj == null) return nil; var ct = (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream'; return #{bb}.$new(obj.body, ct, 'public, max-age=86400'); })`
    end

    # Put a value. `body` may be a String. Returns a JS Promise.
    def put(key, body, content_type = 'application/octet-stream')
      js_bucket = @js
      `#{js_bucket}.put(#{key}, #{body}, { httpMetadata: { contentType: #{content_type} } })`
    end

    # Delete a key. Returns a JS Promise.
    def delete(key)
      js_bucket = @js
      `#{js_bucket}.delete(#{key})`
    end

    # List objects under a prefix. Returns a JS Promise that resolves
    # to a Ruby Array of Hashes, one per object. Each Hash carries the
    # common R2 metadata fields so callers can render a gallery view
    # (key / size / uploaded / httpMetadata['contentType']).
    #
    #   bucket.list(prefix: 'phase11a/uploads/', limit: 50).__await__
    #     => [{ 'key' => 'phase11a/uploads/abc-cat.png',
    #           'size' => 31337, 'uploaded' => '2026-04-17T...',
    #           'content_type' => 'image/png' }, ...]
    #
    # NOTE: R2's `list()` returns bare objects by default — `httpMetadata`
    # is ONLY populated when `include: ['httpMetadata']` is passed in
    # the options. Without it, every row would come back with a
    # fallback `application/octet-stream` content-type even for real
    # PNG uploads. Always requesting httpMetadata is the right default
    # for a gallery UI; callers that need the bytes-only fast path can
    # fall back to listing raw keys + `get()` on-demand.
    def list(prefix: nil, limit: 100, cursor: nil, include: %w[httpMetadata])
      js_bucket = @js
      opts = `({})`
      `#{opts}.prefix = #{prefix}` if prefix
      `#{opts}.limit  = #{limit.to_i}` if limit
      `#{opts}.cursor = #{cursor}` if cursor
      if include && !include.empty?
        js_include = `[]`
        include.each { |v| vs = v.to_s; `#{js_include}.push(#{vs})` }
        `#{opts}.include = #{js_include}`
      end
      `#{js_bucket}.list(#{opts}).then(function(res) { var rows = []; var arr = res && res.objects ? res.objects : []; for (var i = 0; i < arr.length; i++) { var o = arr[i]; var ct = (o.httpMetadata && o.httpMetadata.contentType) || 'application/octet-stream'; var h = new Map(); h.set('key', o.key); h.set('size', o.size|0); h.set('uploaded', o.uploaded ? o.uploaded.toISOString() : null); h.set('content_type', ct); rows.push(h); } return rows; })`
    end
  end
end

# Phase 6 — HTTP client foundation. Loaded as part of the Cloudflare
# Workers adapter so user code can simply `require 'sinatra/base'`
# and use Net::HTTP / Cloudflare::HTTP.fetch without an extra require.
require 'cloudflare_workers/http'

# Phase 9 — Scheduled (Cron Triggers) dispatcher. Installs the JS
# `globalThis.__HOMURABI_SCHEDULED_DISPATCH__` hook that
# `src/worker.mjs#scheduled` forwards every cron firing through.
# Must be loaded after the Cloudflare::* binding wrappers above
# because it constructs D1Database/KVNamespace/R2Bucket instances
# inside the dispatcher's per-job env.
require 'cloudflare_workers/scheduled'

# Phase 10 — Workers AI binding wrapper. Loaded here so any Sinatra
# route can call Cloudflare::AI.run(...) without an extra require.
require 'cloudflare_workers/ai'

# Phase 11A — HTTP foundations.
#
# `multipart` installs a Rack::Request#POST override so Sinatra routes
# can `params['file']` an uploaded file part without any ceremony.
# `stream`    adds `Cloudflare::SSEStream` + `Sinatra::Streaming#sse`
#             so a route can `sse do |out| ... end` and flush chunks
#             through a Workers ReadableStream.
require 'cloudflare_workers/multipart'
require 'cloudflare_workers/stream'

# Phase 11B — Cloudflare native bindings (Durable Objects / Cache /
# Queues). Each file registers its own globalThis dispatcher hook
# where applicable (DO / Queue consumer). Loaded here so user code
# just needs `require 'sinatra/base'` — no extra `require` per
# binding.
require 'cloudflare_workers/cache'
require 'cloudflare_workers/queue'
require 'cloudflare_workers/durable_object'
