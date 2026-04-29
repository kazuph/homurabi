# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11A — Server-Sent Events / streaming response.
#
# Cloudflare Workers speaks streaming via `new Response(readableStream)`.
# The cleanest way to bridge Ruby → streaming JS is a TransformStream:
# Ruby writes to the `writable` side; the runtime flushes the `readable`
# side to the client incrementally.
#
# Public API:
#
#   class App < Sinatra::Base
#     register Sinatra::Streaming
#
#     get '/demo/sse' do
#       sse do |out|
#         5.times do |i|
#           out << "data: tick #{i} — #{Time.now.iso8601}\n\n"
#           out.sleep(1)
#         end
#       end
#     end
#   end
#
# The block runs in a JS async task attached to `ctx.waitUntil`, so the
# Workers isolate stays alive until the stream closes. All writes inside
# the block compile to `await writer.write(encoder.encode(...))`, so
# back-pressure is preserved across the boundary.

module Cloudflare
  # Stream returned from a Sinatra route. `build_js_response` checks
  # `#sse_stream?` and hands the JS readable stream straight to Workers'
  # `new Response(readable, { headers })`.
  class SSEStream
    DEFAULT_HEADERS = {
      'content-type'       => 'text/event-stream; charset=utf-8',
      'cache-control'      => 'no-cache, no-transform',
      'x-accel-buffering'  => 'no',
      'connection'         => 'keep-alive'
    }.freeze

    def initialize(headers: nil, ctx: nil, &block)
      @block = block
      @ctx = ctx
      @extra_headers = headers || {}
      @js_stream = nil
    end

    # Duck-typed marker consumed by Rack::Handler::Homura.
    def sse_stream?
      true
    end

    # Merged header set to emit on the Response.
    def response_headers
      DEFAULT_HEADERS.merge(@extra_headers)
    end

    # Build the JS ReadableStream lazily — build_js_response calls
    # `.js_stream`. After this point the async task is running; we can
    # only do it once per stream.
    def js_stream
      return @js_stream if @js_stream
      blk = @block
      ctx = @ctx
      raise ArgumentError, 'SSEStream needs a block' if blk.nil?

      ts = `new TransformStream()`
      writer = `#{ts}.writable.getWriter()`
      out = SSEOut.new(writer)

      # Kick off the user block in an async task. run_stream compiles
      # to a JS async function (this file is `# await: true`), so
      # calling it returns a Promise; we bind it to ctx.waitUntil so
      # the Workers runtime doesn't tear the isolate down before the
      # stream finishes.
      promise = run_stream(out, blk)
      `#{ctx}.waitUntil(#{promise})` if ctx

      @js_stream = `#{ts}.readable`
    end

    # Rack body contract. Iterating is a no-op — the actual bytes flow
    # through the JS pipe. Sinatra's content-length calculator therefore
    # sees no body and leaves the header out, which is exactly right for
    # a chunked streaming response.
    def each; end
    def close; end

    private

    def run_stream(out, blk)
      begin
        result = blk.call(out)
        # The block may or may not be async. If the block contains any
        # `__await__` / `out.sleep`, Opal compiles it to async and
        # `.call` returns a JS Promise — await it. Otherwise the guard
        # falls through harmlessly. The trailing `.__await__` also
        # forces Opal to mark `run_stream` itself as async — without it
        # the `ensure` branch below would run synchronously BEFORE the
        # awaited block actually finishes and the writer would close
        # after the very first chunk was flushed (bug observed in
        # Phase 11A: /demo/sse sent only `tick 0` then hung up).
        await_if_promise(result).__await__
      rescue ::Exception => e
        begin
          trace = `#{e}.$backtrace ? #{e}.$backtrace().join("\\n") : ''`
          $stderr.puts("[sse] #{e.class}: #{e.message} #{trace}")
        rescue StandardError
          # best-effort; never let logging fail the cleanup branch
        end
      ensure
        # `.__await__` here too, for the same reason: the ensure clause
        # must not return until the writer is actually closed (otherwise
        # the final chunks + `event: close` would race the Response).
        out.close.__await__
      end
    end

    # Await only when the value is thenable; otherwise return as-is.
    # Detection is a JS-side typeof probe — Ruby's `Object#then` (alias
    # of `yield_self` since 2.6) would falsely trigger on ordinary
    # Hashes / Arrays if we used `#respond_to?(:then)`.
    def await_if_promise(val)
      thenable = `(#{val} != null && typeof #{val}.then === 'function')`
      return val unless thenable
      val.__await__
    end
  end

  # Writer side of the SSE pipe. Passed to the user block as `out`.
  # Every write goes through a `TextEncoder` so the bytes hit the
  # client as valid UTF-8 regardless of the Opal String's internal
  # representation.
  #
  # Writes are fire-and-forget: the WritableStream internally queues
  # them in order, so a sequence of `out << a; out << b` always lands
  # on the wire as "ab" without the caller having to manually `.__await__`
  # each write. `close` waits on the tail promise in the chain so it
  # doesn't close the writer mid-queue (which would truncate bytes the
  # client had not yet drained).
  #
  # Memory is O(1) — we chain promises instead of accumulating them in
  # an ever-growing array. A long-lived / high-frequency SSE endpoint
  # therefore doesn't leak once-flushed write-ack promises.
  class SSEOut
    def initialize(writer)
      @writer = writer
      @encoder = `new TextEncoder()`
      # `@tail` tracks only the *latest* pending writer.write()
      # promise. Each write() chains onto it via .then(), so the
      # chain length stays 1 regardless of how many writes have
      # already flushed.
      @tail = `Promise.resolve()`
      @closed = false
    end

    # Write a raw string chunk to the stream. The caller is responsible
    # for SSE framing (e.g. `"data: foo\n\n"`). Returns self.
    def write(data)
      return self if @closed
      s = data.to_s
      w = @writer
      enc = @encoder
      # Chain the write onto the current tail so ordering is still
      # enforced but the promise graph stays flat (Copilot review #3 —
      # prior implementation pushed every write into an unbounded
      # array which would leak memory on long-running streams).
      @tail = `#{@tail}.then(function() { return #{w}.write(#{enc}.encode(#{s})); })`
      self
    end
    alias_method :<<, :write

    # Helper: emit a well-formed SSE event. `data` is split on LF and
    # each line prefixed with `data:` per the SSE spec.
    def event(data, event: nil, id: nil, retry_ms: nil)
      buf = ''
      buf += "event: #{event}\n" if event
      buf += "id: #{id}\n" if id
      buf += "retry: #{retry_ms.to_i}\n" if retry_ms
      data.to_s.split("\n", -1).each { |line| buf += "data: #{line}\n" }
      buf += "\n"
      write(buf)
    end

    # `: keep-alive` comments are the SSE-standard keep-alive mechanism.
    # Browsers / proxies won't drop the connection while they see one.
    def comment(text)
      write(": #{text}\n\n")
    end

    # Suspend the task for `seconds` seconds (Float allowed). Uses
    # setTimeout under the hood so the Workers CPU budget is not
    # charged for wall-clock waiting.
    def sleep(seconds)
      ms = (seconds.to_f * 1000).to_i
      `(new Promise(function(r){ setTimeout(r, #{ms}); }))`.__await__
      self
    end

    # Close the writable side. Waits for the tail promise in the write
    # chain to drain so the client receives the final bytes before
    # `done: true`. After this, subsequent writes become no-ops so a
    # racing producer doesn't crash on a closed writer.
    def close
      return self if @closed
      @closed = true
      w = @writer
      tail = @tail
      # writer.close() itself can reject if the consumer bailed out.
      # Swallow — the Workers runtime already surfaces the underlying
      # error to the client via the HTTP layer. Single-line x-string
      # so Opal emits it as an expression (see Multipart#to_uint8_array
      # for the same gotcha).
      `(async function(t, wr){ try { await t; } catch(e) {} try { await wr.close(); } catch(e) {} })(#{tail}, #{w})`.__await__
      self
    end

    def closed?
      @closed
    end

    # Rack-body compatibility so the SSEOut itself is also iterable by
    # `build_js_response` when used as a body (unusual but supported).
    def each; end
  end
end

# --------------------------------------------------------------------
# Sinatra DSL helper — `sse do |out| ... end`
# --------------------------------------------------------------------

module Sinatra
  module Streaming
    # Emit a Server-Sent Events response. The block receives a writer
    # (`out`) that accepts `<<` (raw string) and `event(data, event:, id:)`
    # for framed events. The block runs in an async task attached to
    # `ctx.waitUntil`, so the isolate stays alive until the block ends.
    def sse(headers: nil, &block)
      ctx = env['cloudflare.ctx']
      ::Cloudflare::SSEStream.new(headers: headers, ctx: ctx, &block)
    end

    # Sinatra本家の `stream do |out| ... end` 互換 DSL。
    # 本家の `Sinatra::Helpers#stream` は Rack EM/Thin で動くスケジューラを
    # 前提にするが、Workers では EventMachine も Thread も無いので
    # 代わりに Cloudflare の `ReadableStream` パスを使う。
    #
    # Call sites look identical to upstream Sinatra:
    #
    #   get '/numbers' do
    #     stream do |out|
    #       10.times do |i|
    #         out << "chunk #{i}\n"
    #         out.sleep(0.1).__await__
    #       end
    #     end
    #   end
    #
    # SSE 用に `stream(type: :sse) do |out| ... end` もサポート。type の
    # デフォルトは `:plain` (text/plain) で、SSE-like ヘッダは付かない。
    # :sse / :event_stream を指定すると Cloudflare::SSEStream::DEFAULT_HEADERS
    # がマージされる（`sse do |out|` と同じ挙動）。
    #
    # `keep_open:` は本家互換だが Workers では意味がない（EM 前提）ため
    # 受け取るだけで使わない。
    def stream(keep_open: false, type: :plain, headers: nil, &block)
      ctx = env['cloudflare.ctx']
      extra_headers = headers || {}
      merged = case type
               when :sse, :event_stream
                 extra_headers  # SSE defaults は SSEStream 側で入る
               else
                 # Plain streaming — start from an empty default set so
                 # the SSE headers don't get force-injected into e.g. a
                 # log-tailing or chunked-JSON endpoint.
                 { 'content-type' => 'text/plain; charset=utf-8' }.merge(extra_headers)
               end
      ::Cloudflare::SSEStream.new(headers: merged, ctx: ctx, &block)
    end

    # Register the helper on a Sinatra app. Use `register Sinatra::Streaming`.
    def self.registered(app)
      app.helpers Streaming
    end
  end
end

# --------------------------------------------------------------------
# Override the stock `Sinatra::Base#stream` so upstream Sinatra apps
# that call it (without registering the helper module) also work on
# Workers. The upstream implementation (vendor/sinatra/base.rb:524)
# defers to EventMachine; Workers has no EM, so we re-route through
# the Cloudflare ReadableStream path. This is explicit: calling
# `register Sinatra::Streaming` still gets you the merging DSL above;
# bare `stream do |out| ... end` still works via this override.
# --------------------------------------------------------------------

module Sinatra
  class Base
    # Re-open to override. We keep the signature compatible with
    # upstream (`stream(keep_open = false, &block)`) but internally
    # route through Cloudflare::SSEStream. Upstream's `Stream` class
    # is not used on Workers (no EventMachine / Thread pool).
    def stream(keep_open = false, &block)
      ctx = env['cloudflare.ctx']
      ::Cloudflare::SSEStream.new(
        headers: { 'content-type' => 'text/plain; charset=utf-8' },
        ctx: ctx,
        &block
      )
    end
  end
end

