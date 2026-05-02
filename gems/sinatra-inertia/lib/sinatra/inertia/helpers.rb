# frozen_string_literal: true

require 'json'
require_relative 'response'

module Sinatra
  module Inertia
    # Sinatra helpers exposed to route handlers. Mounted by the
    # `Sinatra::Inertia` extension.
    module Helpers
      # Render an Inertia response.
      #
      #   render 'Todos/Index', todos: -> { Todo.all }
      #
      # Layout selection: the configured layout (default `:layout`) is
      # rendered for full HTML responses. The view receives `@page_json`
      # (an HTML-escaped JSON string ready to drop into a `data-page`
      # attribute) and `@page` (the underlying Hash, useful for SSR or
      # custom rendering).
      def inertia(component, props: {}, layout: nil)
        layout = current_page_layout if layout.nil?

        version = current_inertia_version
        shared = current_inertia_shared
        encrypt = if !@inertia_encrypt_history_override.nil?
                    @inertia_encrypt_history_override == true
                  elsif settings.respond_to?(:inertia_encrypt_history)
                    settings.inertia_encrypt_history == true
                  else
                    false
                  end
        clear = @inertia_clear_history == true

        # Set the protocol response headers BEFORE we touch any async
        # `to_h` resolution. Under Opal, `Response#to_h` is an `async`
        # function (it `await`s any Proc-returned JS Promise), so the
        # rest of this method runs after a JS-level suspend. Setting
        # `content_type` / `X-Inertia` before the suspend guarantees
        # Sinatra's dispatch sees them when it finalises the response,
        # regardless of how the underlying runtime schedules the
        # awaited continuation.
        if inertia_request?
          content_type 'application/json; charset=utf-8'
          headers 'X-Inertia' => 'true', 'Vary' => 'X-Inertia'
        end

        # Read errors *before* sweeping so the response carries them, then
        # sweep immediately so the next request sees a clean slate. The
        # sweep must happen before any further session writes that the
        # framework might serialise on commit.
        errors_payload = inertia_errors_payload
        sweep_inertia_session!

        response_obj = Sinatra::Inertia::Response.new(
          component: component,
          props: props,
          request: request,
          version: version,
          url: request.fullpath,
          encrypt_history: encrypt,
          clear_history: clear,
          shared: shared,
          errors: errors_payload
        )
        page_hash = response_obj.to_h
        page_json = page_hash.to_json

        return page_json if inertia_request?

        @page = page_hash
        @page_json = ::Rack::Utils.escape_html(page_json)
        erb layout, layout: false
      end

      # Natural page-rendering API: `render 'Component', props_hash`.
      # `render inertia: 'Component', props: {...}` remains available for
      # existing apps, while non-page render calls still delegate to Sinatra.
      # We must preserve Sinatra's `render(engine, data = nil, options = {}, locals = {}, &block)`
      # signature for the non-inertia path, so we forward *args/**kwargs.
      def render(*args, **kwargs, &block)
        first = args.first
        if args.length == 1 && first.is_a?(Hash) && first.key?(:inertia)
          inertia(first[:inertia], props: first[:props] || {}, layout: first[:layout])
        elsif kwargs.key?(:inertia) && args.empty?
          inertia(kwargs[:inertia], props: kwargs[:props] || {}, layout: kwargs[:layout])
        elsif first.is_a?(String) && args.length <= 2 && (args.length == 1 || args[1].is_a?(Hash))
          layout = kwargs.delete(:layout)
          props = {}
          props.merge!(args[1]) if args[1].is_a?(Hash)
          explicit_props = kwargs.delete(:props)
          props.merge!(explicit_props) if explicit_props.is_a?(Hash)
          props.merge!(kwargs)
          inertia(first, props: props, layout: layout)
        else
          super(*args, **kwargs, &block)
        end
      end

      def inertia_request?
        request.env['HTTP_X_INERTIA'] == 'true'
      end

      def page_request?
        inertia_request?
      end

      # CSRF token for the current request. Mounted by CSRFMiddleware
      # (`set :inertia_csrf_protection, true` by default). Pair this with
      # `inertia_share { { csrfToken: csrf_token } }` so the React/Vue
      # client picks it up automatically — but note that when
      # `Sinatra::Inertia::CSRFMiddleware` is active, the cookie + header
      # exchange is already handled by the Inertia client; this helper is
      # mainly for hidden-field forms or non-XHR submissions.
      def csrf_token
        request.env['sinatra.inertia.csrf_token']
      end

      def always(value = nil, &block)
        Sinatra::Inertia.always(value, &block)
      end

      def defer(group: 'default', &block)
        Sinatra::Inertia.defer(group: group, &block)
      end

      def optional(&block)
        Sinatra::Inertia.optional(&block)
      end

      def lazy(&block)
        Sinatra::Inertia.lazy(&block)
      end

      def merge(value = nil, &block)
        Sinatra::Inertia.merge(value, &block)
      end

      # ------------------------------------------------------------------
      # Shared props — runtime accessors (the `inertia_share` class DSL is
      # in extension.rb, this is the per-request resolver).
      def current_inertia_shared
        blocks = settings.inertia_share_blocks || []
        merged = {}
        blocks.each do |b|
          v = instance_exec(&b)
          if v.is_a?(Hash)
            merged = deep_merge(merged, v)
          end
        end
        merged
      end

      # ------------------------------------------------------------------
      # Asset version
      def current_inertia_version
        v = if settings.respond_to?(:page_version)
              settings.page_version
            elsif settings.respond_to?(:inertia_version)
              settings.inertia_version
            end
        v.respond_to?(:call) ? v.call.to_s : v.to_s
      end

      # ------------------------------------------------------------------
      # Errors / flash session sweep (per Inertia validation pattern).
      # Consumers call `inertia_errors(field: 'message')` before redirecting
      # to a form route; the next request renders the form with errors and
      # sweeps them out of the session.
      def inertia_errors(payload = nil)
        if payload.nil?
          (session[:_inertia_errors] || {}).dup
        else
          session[:_inertia_errors] = payload
          payload
        end
      end

      def page_errors(payload = nil)
        inertia_errors(payload)
      end

      def inertia_clear_history!
        @inertia_clear_history = true
      end

      def clear_history!
        inertia_clear_history!
      end

      def inertia_encrypt_history!(flag = true)
        @inertia_encrypt_history_override = flag
      end

      def encrypt_history!(flag = true)
        inertia_encrypt_history!(flag)
      end

      def inertia_errors_payload
        errors = session[:_inertia_errors]
        return nil if errors.nil?
        return nil if errors.respond_to?(:empty?) && errors.empty?
        errors
      end

      def sweep_inertia_session!
        # Rack::Session::Cookie tracks writes by hash mutation. On some
        # session backends (e.g. the JSON-coder cookie store homura uses
        # under Cloudflare Workers) `delete` is a no-op for the *backing
        # cookie* — the change isn't serialised back. Force a write by
        # assigning nil instead, which the JSON encoder still emits as
        # `null` and makes `inertia_errors_payload` treat the field as
        # absent on the next visit.
        if session.respond_to?(:[]=)
          session[:_inertia_errors] = nil
        end
      end

      private

      def current_page_layout
        if settings.respond_to?(:page_layout)
          settings.page_layout
        elsif settings.respond_to?(:inertia_layout)
          settings.inertia_layout
        else
          :layout
        end
      end

      def deep_merge(a, b)
        a.merge(b) do |_k, av, bv|
          (av.is_a?(Hash) && bv.is_a?(Hash)) ? deep_merge(av, bv) : bv
        end
      end
    end
  end
end
