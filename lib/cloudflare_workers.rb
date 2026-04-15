# backtick_javascript: true
# Cloudflare Workers runtime adapter for Opal.
#
# Opal's default `puts` is wired through nodejs.rb's `$stdout`, whose
# `write_proc` calls `process.stdout.write`. On Cloudflare Workers the
# `process.stdout` shim provided by `nodejs_compat` is a Socket that
# is closed inside the isolate, so any `puts` aborts with
# `Uncaught Error: Socket is closed`.
#
# This adapter replaces `$stdout` and `$stderr` with IO-shaped objects
# that delegate to V8's `console.log` / `console.error`. With this
# adapter loaded by Opal at compile time (`opal -I lib -r cloudflare_workers`),
# user Ruby code stays pure: `puts "hi"` Just Works on Workers.
#
# Note: Opal Strings are immutable (they map to JS Strings), so this file
# uses reassignment (`@buffer = @buffer + str`) instead of `<<` mutation.

class CloudflareWorkersIO
  def initialize(channel)
    @channel = channel  # 'log' or 'error'
    @buffer = ''
  end

  # Append data to the line buffer and flush completed lines to console.*
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

  # Mirror Kernel#puts semantics: each arg becomes one line; bare
  # newlines are not duplicated; an empty call prints a blank line.
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

  # Bridge to V8's console.* via Opal's backtick JS escape, and also
  # mirror every emitted line into a global ring buffer so a host
  # JavaScript caller (worker.mjs) can prove from the response side
  # that Ruby code actually executed inside the V8 isolate.
  def emit(line)
    channel = @channel
    text = line
    `
      globalThis.console[#{channel}](#{text});
      var __h = globalThis.__HOMURABI_OUTPUT__ = globalThis.__HOMURABI_OUTPUT__ || [];
      __h.push({channel: #{channel}, text: #{text}, t: Date.now()});
      if (__h.length > 256) { __h.shift(); }
    `
  end
end

$stdout = CloudflareWorkersIO.new('log')
$stderr = CloudflareWorkersIO.new('error')
Object.const_set(:STDOUT, $stdout) unless Object.const_defined?(:STDOUT) && STDOUT.is_a?(CloudflareWorkersIO)
Object.const_set(:STDERR, $stderr) unless Object.const_defined?(:STDERR) && STDERR.is_a?(CloudflareWorkersIO)

# ---------------------------------------------------------------------------
# Homurabi: minimal Ruby-side request/response API for Cloudflare Workers.
#
# This is the Phase 1 piece of the adapter. User Ruby code never touches
# JavaScript — it only ever sees Homurabi::Request, Homurabi::Response, and
# the Homurabi.handle { |req| ... } registration block. The bridge to the
# JS Module Worker (`fetch(request, env, ctx)`) is published as
# `globalThis.__HOMURABI_HANDLE__`; src/worker.mjs forwards every fetch to
# this function and returns whatever JS Response it produces.
#
# Phase 1 is intentionally NOT Sinatra — that arrives in Phase 2 with the
# real janbiedermann/sinatra fork. Phase 1 only proves the request/response
# round-trip can be expressed in pure Ruby.
# ---------------------------------------------------------------------------

module Homurabi
  class Headers
    def initialize(js_headers)
      @js = js_headers
    end

    def [](name)
      key = name.to_s
      `#@js && #@js.get ? #@js.get(#{key}) : null`
    end

    def each
      js = @js
      return self unless js
      `js.forEach(function(value, key) { #{yield(`key`, `value`)} })`
      self
    end
  end

  class Request
    def initialize(js_request)
      @js = js_request
    end

    # Raw underlying JS Request (for advanced use; Sinatra layer in Phase 2
    # will wrap most use cases so consumers should rarely need this).
    def to_js
      @js
    end

    def method
      `#@js.method`
    end

    def url
      `#@js.url`
    end

    def path
      `new URL(#@js.url).pathname`
    end

    def query
      `new URL(#@js.url).search`
    end

    def headers
      @headers ||= Headers.new(`#@js.headers`)
    end

    def body_text
      # Returns a Promise on the JS side — Phase 1 does not need request
      # bodies for the hello-world handler, so we only expose the raw JS
      # object. Phase 2 (Sinatra) will wrap this with await semantics.
      `#@js.text()`
    end
  end

  class Response
    DEFAULT_HEADERS = { 'content-type' => 'text/plain; charset=utf-8' }.freeze

    attr_reader :body, :status, :headers

    def initialize(body = '', status: 200, headers: nil)
      @body = body
      @status = status
      @headers = headers || DEFAULT_HEADERS.dup
    end

    # Convert this Ruby Response into a JS Response object suitable to
    # return from a Module Worker fetch handler.
    def to_js
      body_str = @body.to_s
      status_int = @status.to_i
      js_headers = `({})`
      @headers.each do |k, v|
        ks = k.to_s
        vs = v.to_s
        `js_headers[#{ks}] = #{vs}`
      end
      `new Response(#{body_str}, { status: #{status_int}, headers: js_headers })`
    end
  end

  class << self
    attr_reader :handler

    # Register the request handler. Block receives a Homurabi::Request and
    # may return either a Homurabi::Response or any object whose to_s is
    # the response body.
    def handle(&block)
      @handler = block
      install_global_dispatcher
      block
    end

    def dispatch(js_req, js_env, js_ctx)
      raise 'Homurabi.handle has not been called yet' unless @handler

      request = Request.new(js_req)
      result = @handler.call(request)
      response = result.is_a?(Response) ? result : Response.new(result.to_s)
      response.to_js
    end

    private

    def install_global_dispatcher
      mod = self
      `
        globalThis.__HOMURABI_HANDLE__ = function(req, env, ctx) {
          return #{mod}.$dispatch(req, env, ctx);
        };
      `
    end
  end
end
