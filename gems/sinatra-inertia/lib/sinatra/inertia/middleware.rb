# frozen_string_literal: true

module Sinatra
  module Inertia
    # Rack middleware handling concerns that must run *outside* the Sinatra
    # request cycle:
    #
    #   * Version-mismatch detection. Per the Inertia protocol, an Inertia
    #     GET visit whose `X-Inertia-Version` header disagrees with the
    #     server's current asset version must be answered with
    #     `409 Conflict` and a `X-Inertia-Location` header pointing at the
    #     same URL — the client then performs a hard reload.
    #
    #   * Forced 303 redirects for non-GET requests. Inertia requires the
    #     client follow the redirect with a GET, which only happens when the
    #     server uses 303 See Other (the default 302 turns into a method-
    #     preserving redirect on some browsers).
    #
    # The middleware is `register`-ed automatically by `Sinatra::Inertia`
    # via `app.use`, so consumer apps don't need to wire it manually.
    class Middleware
      INERTIA_HEADER = 'HTTP_X_INERTIA'
      INERTIA_VERSION_HEADER = 'HTTP_X_INERTIA_VERSION'

      def initialize(app, version:)
        @app = app
        @version = version
      end

      def call(env)
        if inertia_get?(env) && version_mismatch?(env)
          location = env['REQUEST_URI'] || build_url(env)
          return [
            409,
            { 'X-Inertia-Location' => location, 'Vary' => 'X-Inertia' },
            []
          ]
        end

        status, headers, body = @app.call(env)

        # Promote 302 → 303 for Inertia non-GET visits so the client follows
        # the redirect with a GET. Strictly limited to `X-Inertia: true`
        # requests: a Sinatra app may serve plain REST endpoints alongside
        # Inertia pages, and rewriting their 302s would silently change
        # HTTP semantics for non-Inertia clients.
        if status == 302 && env[INERTIA_HEADER] == 'true' &&
           %w[POST PUT PATCH DELETE].include?(env['REQUEST_METHOD'])
          status = 303
        end

        [status, headers, body]
      end

      private

      def inertia_get?(env)
        env[INERTIA_HEADER] == 'true' && env['REQUEST_METHOD'] == 'GET'
      end

      def version_mismatch?(env)
        current = current_version
        return false if current.nil? || current.empty?
        env[INERTIA_VERSION_HEADER].to_s != current
      end

      def current_version
        v = @version.respond_to?(:call) ? @version.call : @version
        v.to_s
      end

      def build_url(env)
        scheme = env['rack.url_scheme'] || 'http'
        host = env['HTTP_HOST'] || env['SERVER_NAME']
        path = env['PATH_INFO']
        qs = env['QUERY_STRING']
        full = +"#{scheme}://#{host}#{path}"
        full << "?#{qs}" if qs && !qs.empty?
        full
      end
    end
  end
end
