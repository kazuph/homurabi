# frozen_string_literal: true
#
# Phase 13 — Opal / Cloudflare Workers compatibility patches for
# upstream sinatra/sinatra v4.2.1.
#
# vendor/sinatra/ tracks the pristine upstream release bit-identically;
# this file applies every deviation needed to make Sinatra run inside
# the Cloudflare Workers isolate via Opal. Each override here has a
# header comment tagging the upstream line that changed.
#
# Philosophy: reopen the existing class/module and redefine the
# affected methods. Keep each patch as narrow as possible so the next
# `bundle gem sinatra; bump VERSION` can be applied with confidence
# that the regressions are visible here in one file.
#
# The Regression harness for these patches is the full npm test suite
# (378 cases across 15 smoke files) plus `/test/crypto`,
# `/test/sequel`, `/test/jwt`, `/test/scheduled` and the dogfooded
# routes in app/hello.rb.

require 'cgi'
require 'sinatra/base'

module Sinatra
  # ---------------------------------------------------------------
  # 1. Request#forwarded? (upstream base.rb:66)
  #
  # Upstream: `!forwarded_authority.nil?` — checks a Rack 3.1 helper
  # that isn't bundled by our Rack vendor shim.
  # homura: raw header presence check — the Cloudflare runtime
  # always normalises X-Forwarded-Host when a proxy fronts the Worker.
  # ---------------------------------------------------------------
  class Request < Rack::Request
    def forwarded?
      @env.include?('HTTP_X_FORWARDED_HOST')
    end
  end

  # ---------------------------------------------------------------
  # 1.5. HaltResponse
  #
  # `throw :halt` cannot cross an async boundary in Opal: once a
  # `# await: true` route has yielded to a Promise, the eventual throw
  # resumes on a later tick and bypasses Sinatra's outer
  # `catch(:halt)`. We therefore represent explicit `halt` calls as an
  # Exception carrying the fully-materialized Rack tuple. Synchronous
  # routes still terminate immediately; async routes can resolve the
  # rejection back into a response in `invoke` / `build_js_response`.
  # ---------------------------------------------------------------
  class HaltResponse < ::Exception
    attr_reader :payload

    def initialize(payload)
      @payload = payload
      super('halt')
    end
  end

  # ---------------------------------------------------------------
  # 2. Response#calculate_content_length? (upstream base.rb:208)
  #
  # Upstream returns true iff content-type is set, content-length is
  # missing, and body is an Array. If any Array element is a native
  # JS Promise (routes compiled `# await: true` return their body as
  # a Promise until the adapter resolves it), computing bytesize would
  # poison the response. Opt out in that case so
  # Rack::Handler::CloudflareWorkers#build_js_response can await and
  # set content-length downstream.
  # ---------------------------------------------------------------
  class Response
    private

    def calculate_content_length?
      return false unless headers['content-type']
      return false if headers['content-length']
      return false unless Array === body
      return false if defined?(::Cloudflare) &&
                      body.any? { |c| ::Cloudflare.js_promise?(c) || c.is_a?(::Cloudflare::BinaryBody) }
      true
    end
  end

  # ---------------------------------------------------------------
  # 3. Helpers#body= (upstream base.rb:300)
  #
  # Upstream uses Rack::Files::BaseIterator which exists on Rack 3.x
  # CRuby but not in homura's vendored Rack. The public Iterator
  # class is available, so swap to it.
  # ---------------------------------------------------------------
  module Helpers
    def body(value = nil, &block)
      if block_given?
        def block.each; yield(call) end
        response.body = block
      elsif value
        files_iterator = defined?(::Rack::Files::Iterator) ? ::Rack::Files::Iterator : nil
        stream_cls     = defined?(::Sinatra::Stream) ? ::Sinatra::Stream : nil
        unless request.head? ||
               (files_iterator && value.is_a?(files_iterator)) ||
               (stream_cls && value.is_a?(stream_cls))
          headers.delete('content-length')
        end
        response.body = value
      else
        response.body
      end
    end

    # -------------------------------------------------------------
    # 3.5. Helpers#halt (upstream base.rb:1030)
    #
    # Upstream uses `throw :halt`. That works for synchronous Ruby, but
    # not once an Opal-compiled route has crossed an async boundary.
    # Snapshot the final Rack tuple and raise a dedicated exception so
    # both sync and async routes preserve Sinatra semantics.
    # -------------------------------------------------------------
    def halt(*halt_response)
      raise HaltResponse.new(materialize_halt_payload(*halt_response))
    end

    # -------------------------------------------------------------
    # 4. Helpers#uri (upstream base.rb:330)
    #
    # Upstream mutates `host` with `<<`. Opal Strings are JS Strings
    # and therefore immutable, so we build with `+` and reassignment.
    # -------------------------------------------------------------
    def uri(addr = nil, absolute = true, add_script_name = true)
      return addr if addr.to_s =~ /\A[a-z][a-z0-9+.\-]*:/i

      host = ''
      if absolute
        host = host + "http#{'s' if request.secure?}://"
        host = host + if request.forwarded? || (request.port != (request.secure? ? 443 : 80))
                       request.host_with_port
                     else
                       request.host
                     end
      end
      uri = [host]
      uri << request.script_name.to_s if add_script_name
      uri << (addr || request.path_info).to_s
      File.join(uri)
    end

    # -------------------------------------------------------------
    # 5. Helpers#content_type (upstream base.rb:400)
    #
    # Upstream uses `mime_type << ';'` and `mime_type << params...`.
    # Opal Strings are immutable. Also the upstream string join uses
    # `';'` which doesn't match CGI convention for content-type; the
    # homura port switched to `, ` between key=value params to match
    # how Rack normalises Content-Type. Preserved that behaviour here.
    # -------------------------------------------------------------
    def content_type(type = nil, params = {})
      return response['content-type'] unless type

      default = params.delete :default
      mime_type = mime_type(type) || default
      raise format('Unknown media type: %p', type) if mime_type.nil?

      mime_type = mime_type.dup
      unless params.include?(:charset) || settings.add_charset.all? { |p| !(p === mime_type) }
        params[:charset] = params.delete('charset') || settings.default_encoding
      end
      params.delete(:charset) if mime_type.include?('charset')
      unless params.empty?
        mime_type += (mime_type.include?(';') ? ', ' : ';')
        mime_type += params.map do |key, val|
          val = val.inspect if val =~ /[";,]/
          "#{key}=#{val}"
        end.join(', ')
      end
      response['content-type'] = mime_type
    end

    # -------------------------------------------------------------
    # 6. Helpers#etag_matches? (upstream base.rb:722)
    #
    # Minor: upstream splits on ',' and strips each entry. Regex split
    # is equivalent and slightly faster.
    # -------------------------------------------------------------
    def etag_matches?(list, new_resource = request.post?)
      return !new_resource if list == '*'

      list.to_s.split(/\s*,\s*/).include?(response['ETag'])
    end

    private

    def materialize_halt_payload(*halt_response)
      final_status = response.status
      final_headers = response.headers.dup
      final_body = response.body

      return [final_status, final_headers, final_body] if halt_response.empty?

      res = halt_response.length == 1 ? halt_response.first : halt_response
      res = [res] if (Integer === res) || (String === res)

      if (Array === res) && (Integer === res.first)
        parts = res.dup
        final_status = Rack::Utils.status_code(parts.shift)
        final_body = parts.empty? ? nil : parts.pop
        parts.each do |header_set|
          next unless header_set.respond_to?(:each)

          header_set.each { |key, value| final_headers[key.to_s] = value }
        end
      elsif res.respond_to?(:each)
        final_body = res
      else
        final_body = res
      end

      [final_status, final_headers, final_body]
    end
  end

  # ---------------------------------------------------------------
  # 7. Base#static! (upstream base.rb:1147)
  #
  # Upstream: URI_INSTANCE.unescape — URI_INSTANCE is defined in
  # upstream as URI::RFC2396_PARSER (populated in opal_patches.rb
  # with a CGI-backed stand-in), so this works today. The homura
  # port also dropped the `static_headers` setting (not used on
  # Workers — static files are served from R2 or a CDN, not from
  # per-request Ruby response headers). Keeping parity here.
  # ---------------------------------------------------------------
  class Base
    private

    def static!(options = {})
      return if (public_dir = settings.public_folder).nil?

      path = "#{public_dir}#{::CGI.unescape(request.path_info)}"
      return unless valid_path?(path)

      path = File.expand_path(path)
      return unless path.start_with?("#{File.expand_path(public_dir)}/")

      return unless File.file?(path)

      env['sinatra.static_file'] = path
      cache_control(*settings.static_cache_control) if settings.static_cache_control?
      send_file(path, options.merge(disposition: nil))
    end

    # -------------------------------------------------------------
    # 8. Base#invoke (upstream base.rb:1167)
    #
    # Upstream decides body by shape (Integer / String / Array / each).
    # homura adds a fourth case: a native JS Promise (routes with
    # `# await: true` implicitly return a Promise from async function
    # wrapping). Wrap it as a single-chunk Array so the Cloudflare
    # handler (`Rack::Handler::CloudflareWorkers#build_js_response`)
    # can detect and await. We can't rely on `respond_to? :then`
    # because Ruby's Kernel#then (alias of yield_self) matches every
    # object since 2.6.
    #
    # NOTE (copilot review #12): upstream declares `invoke` after a
    # `private` visibility marker. Reopen the class under the same
    # visibility by re-applying `private :invoke` right after the
    # redefinition, so we don't expand Sinatra::Base's public surface.
    # -------------------------------------------------------------
    def invoke(&block)
      res = catch(:halt, &block)
      apply_invoke_result(wrap_async_halt_result(res))
      nil
    rescue HaltResponse => e
      apply_invoke_result(e.payload)
      nil
    end
    private :invoke

    def apply_invoke_result(res)
      res = [res] if (Integer === res) || (String === res)
      if (Array === res) && (Integer === res.first)
        res = res.dup
        status(res.shift)
        body(res.pop)
        headers(*res)
      elsif res.respond_to?(:each)
        body(res)
      elsif defined?(::Cloudflare) && ::Cloudflare.js_promise?(res)
        body([res])
      end
    end
    private :apply_invoke_result

    def wrap_async_halt_result(res)
      return res unless defined?(::Cloudflare) && ::Cloudflare.js_promise?(res)

      halt_class = ::Sinatra::HaltResponse
      halt_tag = :halt
      `#{res}.catch(function(error) {
        try {
          if (error != null && typeof error['$is_a?'] === 'function' && error['$is_a?'](#{halt_class})) {
            return error['$payload']();
          }
          if (error != null && typeof error['$tag'] === 'function' && typeof error['$value'] === 'function' && error['$tag']() === #{halt_tag}) {
            return error['$value']();
          }
        } catch (_) {}
        throw error;
      })`
    end
    private :wrap_async_halt_result

    # -------------------------------------------------------------
    # 9. Base.new! (upstream base.rb:1676)
    #
    # Upstream uses `alias new! new unless method_defined? :new!` on
    # the singleton class. Opal's alias-into-class<<self does not
    # preserve the target correctly — calling new! raises NoMethodError
    # at runtime. Define it explicitly via allocate+initialize.
    # -------------------------------------------------------------
    class << self
      def new!(*args, &block)
        instance = allocate
        instance.send(:initialize, *args, &block)
        instance
      end

      # -----------------------------------------------------------
      # 10. Base.setup_default_middleware (upstream base.rb:1846)
      #
      # Upstream invokes `setup_host_authorization` which uses IPAddr.
      # homura does not use host_authorization on Workers (the
      # request host is always whitelisted by the Worker binding
      # itself; permitted_hosts is moot). Skip that middleware.
      # -----------------------------------------------------------
      def setup_default_middleware(builder)
        builder.use ExtendedRack
        builder.use ShowExceptions       if show_exceptions?
        builder.use ::Rack::MethodOverride if method_override?
        builder.use ::Rack::Head
        setup_logging(builder)
        setup_sessions(builder)
        setup_protection(builder)
        # NOTE: upstream calls `setup_host_authorization builder` here.
        # On Cloudflare Workers the host whitelist is enforced by the
        # wrangler.toml binding configuration itself, and the
        # `Rack::Protection::HostAuthorization` middleware is not vendored
        # (would require IPAddr, also stubbed in homura). Skipping it
        # is functionally equivalent in our deployment model.
      end

      # -----------------------------------------------------------
      # 11. NOTE: previous drafts of this patch file replaced
      # `setup_null_logger` / `setup_custom_logger` with Rack::Logger
      # middleware, but homura's vendored Rack does not ship
      # `Rack::Logger` (it ships `Rack::NullLogger` and
      # `Rack::CommonLogger` only). Upstream Sinatra's original
      # `Sinatra::Middleware::Logger` is vendored bit-identically
      # under vendor/sinatra_upstream/middleware/logger.rb and works
      # against Opal's stdlib Logger (vendor/opal-gem/stdlib/logger.rb).
      # No override required — upstream's implementation is reused.
      # -----------------------------------------------------------

      # -----------------------------------------------------------
      # 12. Base.force_encoding (upstream base.rb:1942)
      #
      # Upstream calls `.force_encoding(encoding).encode!`. Opal's
      # String#encode! raises NotImplementedError (JS Strings are
      # immutable UTF-16). force_encoding alone is a no-op that
      # returns the same String object. Drop encode!.
      # -----------------------------------------------------------
      def force_encoding(data, encoding = default_encoding)
        return if data == settings || data.is_a?(Tempfile)

        if data && data.respond_to?(:force_encoding)
          data.force_encoding(encoding)
        elsif data.respond_to?(:each_value)
          data.each_value { |v| force_encoding(v, encoding) }
        elsif data.respond_to?(:each)
          data.each { |v| force_encoding(v, encoding) }
        end

        data
      end
    end

    # -------------------------------------------------------------
    # 12.5. Base#dispatch! (upstream base.rb:1183)
    #
    # Some Rack param parsing paths can leak raw JS `undefined` values
    # into `@request.params` under Opal. Sending Ruby messages to that
    # sentinel crashes before Sinatra gets to route dispatch. Short-
    # circuit on falsy values so sync/async apps both survive these
    # malformed param entries.
    # -------------------------------------------------------------
    def dispatch!
      @params.merge!(@request.params).each do |key, val|
        next unless val && val.respond_to?(:force_encoding)

        val = val.dup if val.frozen?
        @params[key] = force_encoding(val)
      end

      invoke do
        static! if settings.static? && (request.get? || request.head?)
        filter! :before do
          @pinned_response = !response['content-type'].nil?
        end
        route!
      end
    rescue ::Exception => e
      invoke { handle_exception!(e) }
    ensure
      begin
        filter! :after unless env['sinatra.static_file']
      rescue ::Exception => e
        invoke { handle_exception!(e) } unless @env['sinatra.error']
      end
    end
    private :dispatch!
  end

  # ---------------------------------------------------------------
  # 13. Delegator.delegate (upstream base.rb:2113)
  #
  # Upstream first probes `return super(*args, &block) if respond_to?
  # method_name`. Opal's `super` inside `define_method` is hard-wired
  # to the enclosing Ruby method name ('delegate') at compile time
  # instead of resolving to the dynamically defined method, which
  # breaks top-level `get '/' do ... end` on the main object. Skip
  # the super probe; the delegator is the sole hook for main, so
  # Delegator.target.send(...) is always the right dispatch.
  # ---------------------------------------------------------------
  module Delegator
    def self.delegate(*methods)
      methods.each do |method_name|
        define_method(method_name) do |*args, &block|
          Delegator.target.send(method_name, *args, &block)
        end
        # Preserve upstream's ruby2_keywords semantics so classic-mode
        # DSL methods that accept `**options` (before / after /
        # configure / helpers / set / ...) forward keyword arguments
        # correctly on Ruby 2.7+ (Copilot review on PR #12).
        ruby2_keywords(method_name) if respond_to?(:ruby2_keywords, true)
        private method_name
      end
    end
  end

  # Upstream `Sinatra::Delegator.delegate(:get, :post, :enable, ...)` on
  # base.rb:2117 runs BEFORE sinatra_opal_patches.rb loads, so those
  # methods were defined by the ORIGINAL `delegate` body (which probes
  # `return super(*args, &block) if respond_to?(method_name)`). In Opal
  # `super` inside `define_method` resolves against the compile-time
  # enclosing method name (`delegate`) — not the dynamically-defined
  # target — and explodes when top-level `enable :inline_templates`
  # triggers it on the `main` object ("super: no superclass method
  # `enable'"). Re-delegate the canonical upstream list NOW so every
  # instance method is regenerated with the patched body.
  Delegator.delegate(
    :get, :patch, :put, :post, :delete, :head, :options, :link, :unlink,
    :template, :layout, :before, :after, :error, :not_found, :configure,
    :set, :mime_type, :enable, :disable, :use, :development?, :test?,
    :production?, :helpers, :settings, :register, :on_start, :on_stop
  )
end

# ---------------------------------------------------------------
# 14. Drop host_authorization / static_headers settings
#
# Upstream sets these in the class body. They read settings that
# depend on IPAddr (for host_authorization default) which is stubbed
# in homura, so leaving them set is inert. Clearing static_headers
# just removes a no-op `headers(...)` call from `static!`, which we
# already overrode above.
# ---------------------------------------------------------------
Sinatra::Base.set :host_authorization, {} if Sinatra::Base.respond_to?(:host_authorization)
Sinatra::Base.set :static_headers, false if Sinatra::Base.respond_to?(:static_headers)
