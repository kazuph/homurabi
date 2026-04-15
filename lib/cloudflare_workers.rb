# backtick_javascript: true
# Cloudflare Workers runtime adapter for Opal.
#
# This file is the only place in the homurabi codebase that knows the
# underlying transport is Cloudflare Workers. Its job is to make CF Workers
# look like any other Rack server (Puma, Unicorn, Falcon, WEBrick, ...).
# User Ruby code is therefore a plain Rack application and would run
# unchanged on any Rack-compatible host.
#
# Two responsibilities, both modelled after existing Ruby conventions:
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
# Note: Opal Strings are immutable (they map to JS Strings), so this file
# uses reassignment (`@buffer = @buffer + str`) instead of `<<` mutation.

require 'stringio'

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
            globalThis.__HOMURABI_RACK_DISPATCH__ = function(req, env, ctx, body_text) {
              return #{handler}.$call(req, env, ctx, body_text == null ? "" : body_text);
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
        def build_js_response(status, headers, body)
          body_str = ''
          if body.respond_to?(:each)
            body.each { |chunk| body_str = body_str + chunk.to_s }
          else
            body_str = body.to_s
          end

          js_headers = `({})`
          headers.each do |k, v|
            ks = k.to_s
            vs = v.to_s
            `#{js_headers}[#{ks}] = #{vs}`
          end

          status_int = status.to_i
          `new Response(#{body_str}, { status: #{status_int}, headers: #{js_headers} })`
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

module Kernel
  private

  def run(app, **options)
    Rack::Handler::CloudflareWorkers.run(app, **options)
  end
end
