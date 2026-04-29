# frozen_string_literal: true

require 'securerandom'
require 'rack/utils'

module Sinatra
  module Inertia
    # Rack middleware implementing the Inertia / Laravel "double-submit
    # cookie" CSRF pattern that `@inertiajs/react` and `@inertiajs/vue3`
    # honour out of the box.
    #
    # Behaviour
    # ---------
    # * On every request, ensure a token cookie named `XSRF-TOKEN` is
    #   present (generate + set on the response if missing).
    # * For non-safe methods (POST / PUT / PATCH / DELETE), require the
    #   request to send `X-XSRF-TOKEN` whose value matches the cookie.
    #   Mismatch → `403 Forbidden`.
    # * The cookie is *not* HttpOnly — Inertia's client reads it from
    #   `document.cookie` and forwards it as `X-XSRF-TOKEN` automatically.
    #
    # Caveats
    # -------
    # Double-submit cookie is the standard Inertia/Laravel pattern but is
    # weaker than synchronizer-token CSRF when an attacker has any
    # script-injection foothold. Pair with:
    #   * `SameSite=Lax` (default below) — the cookie won't ride
    #     cross-site form posts.
    #   * Strict CSP / no XSS.
    #   * Optionally, server-side session-bound tokens via
    #     `Rack::Protection::AuthenticityToken` instead.
    #
    # Configuration
    # -------------
    # `set :inertia_csrf_protection, false` disables this middleware. Use
    # this only when the consumer ships its own CSRF defence. Safer
    # defaults assume the gem is responsible.
    class CSRFMiddleware
      COOKIE_NAME = 'XSRF-TOKEN'
      HEADER_KEY = 'HTTP_X_XSRF_TOKEN'
      ENV_TOKEN_KEY = 'sinatra.inertia.csrf_token'
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      def initialize(app, same_site: :Lax)
        @app = app
        @same_site = same_site
      end

      def call(env)
        existing = read_cookie(env)
        token = existing || SecureRandom.urlsafe_base64(32)
        env[ENV_TOKEN_KEY] = token

        unless safe_method?(env)
          header = env[HEADER_KEY].to_s
          if existing.nil? || header.empty? || !secure_compare(header, existing)
            return forbidden('CSRF token mismatch (expected matching X-XSRF-TOKEN header to XSRF-TOKEN cookie)')
          end
        end

        status, headers, body = @app.call(env)
        unless existing == token
          set_cookie!(headers, token)
        end
        [status, headers, body]
      end

      private

      def safe_method?(env)
        SAFE_METHODS.include?(env['REQUEST_METHOD'])
      end

      def read_cookie(env)
        cookie_header = env['HTTP_COOKIE'].to_s
        return nil if cookie_header.empty?
        cookie_header.split(/;\s*/).each do |pair|
          name, value = pair.split('=', 2)
          next unless name == COOKIE_NAME
          return value
        end
        nil
      end

      def secure_compare(a, b)
        # Constant-time compare. Avoid Rack::Utils.secure_compare here:
        # the upstream implementation calls
        # `OpenSSL.fixed_length_secure_compare` first, and on the homura
        # Opal-on-Workers build that path either raises or silently
        # diverges. Pure-Ruby compare keeps behaviour identical between
        # MRI and Opal.
        a = a.to_s
        b = b.to_s
        return false if a.bytesize != b.bytesize
        diff = 0
        a.bytes.zip(b.bytes) { |ai, bi| diff |= ai ^ bi }
        diff.zero?
      end

      def set_cookie!(headers, token)
        attrs = "#{COOKIE_NAME}=#{token}; Path=/; SameSite=#{@same_site}"
        existing = headers['Set-Cookie']
        # Normalise to a newline-joined String regardless of Rack 2/3
        # conventions or downstream worker-runtime quirks. The Cloudflare
        # Workers adapter that homura ships with serialises Array-shaped
        # `Set-Cookie` headers as a literal JSON array, which breaks
        # cookie parsing on the client.
        prev = case existing
               when nil, '' then nil
               when Array then existing.join("\n")
               else existing.to_s
               end
        headers['Set-Cookie'] = prev ? "#{prev}\n#{attrs}" : attrs
      end

      def forbidden(message)
        body = "#{message}\n"
        [403, {
          'Content-Type' => 'text/plain; charset=utf-8',
          'Content-Length' => body.bytesize.to_s
        }, [body]]
      end
    end
  end
end
