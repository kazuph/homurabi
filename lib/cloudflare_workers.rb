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
              // The Ruby .$call may return either a plain Response (sync
              // route) or a Promise<Response> (a route that awaited on a
              // D1 / KV / R2 binding). Await unconditionally; awaiting a
              // plain Response just resolves to it.
              return await #{handler}.$call(req, env, ctx, body_text == null ? "" : body_text);
            };
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
          env['cloudflare.DB']     = Cloudflare::D1Database.new(js_db)  if `#{js_db} != null`
          env['cloudflare.KV']     = Cloudflare::KVNamespace.new(js_kv) if `#{js_kv} != null`
          env['cloudflare.BUCKET'] = Cloudflare::R2Bucket.new(js_r2)    if `#{js_r2} != null`

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
            `Promise.all(#{js_chunks}).then(function(resolved) { var parts = []; for (var i = 0; i < resolved.length; i++) { var r = resolved[i]; if (r == null) { parts.push(''); continue; } if (typeof r === 'string') { parts.push(r); continue; } if (r != null && r.$$is_string) { parts.push(r.toString()); continue; } try { parts.push(JSON.stringify(r)); } catch (e) { parts.push(String(r)); } } return new Response(parts.join(''), { status: #{status_int}, headers: #{js_headers} }); })`
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
      `#{js_stmt}.all().then(function(res) { return #{cf}.$js_rows_to_ruby(res.results); })`
    end

    # Returns a JS Promise that resolves to a single Ruby Hash (or nil).
    def first
      js_stmt = @js
      cf = Cloudflare
      `#{js_stmt}.first().then(function(res) { return res == null ? nil : #{cf}.$js_object_to_hash(res); })`
    end

    # Returns a JS Promise that resolves to a Ruby Hash with the D1 meta.
    def run
      js_stmt = @js
      cf = Cloudflare
      `#{js_stmt}.run().then(function(res) { return #{cf}.$js_object_to_hash(res); })`
    end
  end

  class KVNamespace
    def initialize(js)
      @js = js
    end

    # KV#get returns a JS Promise resolving to a String or nil.
    def get(key)
      js_kv = @js
      `#{js_kv}.get(#{key}, "text").then(function(v) { return v == null ? nil : v; })`
    end

    # Put a value. Returns a JS Promise.
    def put(key, value)
      js_kv = @js
      `#{js_kv}.put(#{key}, #{value})`
    end

    # Delete a key. Returns a JS Promise.
    def delete(key)
      js_kv = @js
      `#{js_kv}.delete(#{key})`
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

    # R2 get_raw. Returns the raw body as a String (for serving binary
    # content like images). Returns nil if the object doesn't exist.
    def get_raw(key)
      js_bucket = @js
      `#{js_bucket}.get(#{key}).then(async function(obj) { if (obj == null) return nil; var buf = await obj.arrayBuffer(); return new Uint8Array(buf); })`
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
  end
end
