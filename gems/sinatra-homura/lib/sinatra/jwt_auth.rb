# frozen_string_literal: true
# await: true
#
# Phase 8 — Sinatra::JwtAuth
#
# A thin Sinatra extension that wraps the vendored jwt gem so a route
# body can do:
#
#     get '/api/me' do
#       auth_status, auth_result = authenticate_or_401
#       next [auth_status, auth_result] if auth_status
#       content_type 'application/json'
#       { 'user' => current_user }.to_json
#     end
#
# Registration (anywhere before routes that need auth):
#
#     class App < Sinatra::Base
#       register Sinatra::JwtAuth
#       set :jwt_secret, 'super-secret'      # HS256 default
#       set :jwt_algorithm, 'HS256'          # or 'RS256' / 'ES256' / 'EdDSA'
#       # For asymmetric algos, set both keys explicitly:
#       # set :jwt_sign_key,   private_key
#       # set :jwt_verify_key, public_key
#     end
#
# The extension:
#   - Reads the `Authorization: Bearer <token>` header from the incoming
#     request.
#   - Verifies the token with the configured algorithm.
#   - On success, populates `@current_user` from the JWT payload (the
#     full decoded Hash). Helpers `current_user` / `jwt_payload` expose
#     the decoded Hash, and `jwt_header` exposes the decoded header.
#   - `authenticate!` halts with 401 JSON `{ "error": "..." }` on any
#     verification failure (missing header, malformed token, expired,
#     etc.).
#
# `issue_token(payload, expires_in: 3600, extra_headers: {})` is
# provided as a helper so login routes can mint JWTs with the same
# configured algorithm and keys without re-plumbing.

require 'json'
require 'jwt'

module Sinatra
  module JwtAuth
    module Helpers
      # Returns the decoded payload Hash, or nil if the request has not
      # been authenticated (or authentication failed).
      def current_user
        @jwt_payload
      end

      def jwt_payload
        @jwt_payload
      end

      def jwt_header
        @jwt_header
      end

      # Halts with 401 JSON if the Bearer token is missing, malformed,
      # or fails cryptographic / claims verification. On success, sets
      # @jwt_payload / @jwt_header for use in the route body.
      #
      # DEPRECATED: This helper uses +halt+, which throws past Opal's
      # async boundary in # await: true routes. Use +authenticate_or_401+
      # instead and handle the returned +[status, body]+ tuple explicitly.
      def authenticate!
        warn "DEPRECATION WARNING: authenticate! uses halt which is unsafe in async routes. Use authenticate_or_401 instead."
        token = extract_bearer_token
        halt_unauthorized!('missing bearer token') if token.nil?

        verify_key = settings.respond_to?(:jwt_verify_key) && settings.jwt_verify_key ? settings.jwt_verify_key : settings.jwt_secret
        algorithm  = settings.respond_to?(:jwt_algorithm) ? settings.jwt_algorithm : 'HS256'

        begin
          payload, header = JWT.decode(token, verify_key, true, algorithm: algorithm).__await__
        rescue JWT::ExpiredSignature
          halt_unauthorized!('token expired')
        rescue JWT::ImmatureSignature
          halt_unauthorized!('token not yet valid')
        rescue JWT::IncorrectAlgorithm
          halt_unauthorized!('algorithm mismatch')
        rescue JWT::VerificationError
          halt_unauthorized!('signature verification failed')
        rescue JWT::DecodeError => e
          halt_unauthorized!("invalid token: #{e.message}")
        end

        @jwt_payload = payload
        @jwt_header  = header
        payload
      end

      # Safe async-friendly authentication helper.
      # Returns +[nil, payload]+ on success, or +[401, json_body]+ on failure.
      # Does NOT use +halt+ — the caller is responsible for checking the
      # status and returning early with +status N; next(body)+.
      def authenticate_or_401
        token = extract_bearer_token
        return [401, { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json] if token.nil?

        verify_key = settings.respond_to?(:jwt_verify_key) && settings.jwt_verify_key ? settings.jwt_verify_key : settings.jwt_secret
        algorithm  = settings.respond_to?(:jwt_algorithm) ? settings.jwt_algorithm : 'HS256'

        begin
          payload, header = JWT.decode(token, verify_key, true, algorithm: algorithm).__await__
        rescue JWT::ExpiredSignature
          return [401, { 'error' => 'unauthorized', 'reason' => 'token expired' }.to_json]
        rescue JWT::ImmatureSignature
          return [401, { 'error' => 'unauthorized', 'reason' => 'token not yet valid' }.to_json]
        rescue JWT::IncorrectAlgorithm
          return [401, { 'error' => 'unauthorized', 'reason' => 'algorithm mismatch' }.to_json]
        rescue JWT::VerificationError
          return [401, { 'error' => 'unauthorized', 'reason' => 'signature verification failed' }.to_json]
        rescue JWT::DecodeError => e
          return [401, { 'error' => 'unauthorized', 'reason' => "invalid token: #{e.message}" }.to_json]
        end

        @jwt_payload = payload
        @jwt_header  = header
        [nil, payload]
      end

      # Mints a new token using the configured signing key + algorithm.
      # `expires_in` adds an `exp` claim in seconds from now; pass nil
      # to leave it off. `extra_headers` is merged into the JWT header
      # alongside the alg.
      def issue_token(payload, expires_in: 3600, extra_headers: {})
        sign_key  = settings.respond_to?(:jwt_sign_key) && settings.jwt_sign_key ? settings.jwt_sign_key : settings.jwt_secret
        algorithm = settings.respond_to?(:jwt_algorithm) ? settings.jwt_algorithm : 'HS256'
        claims    = payload.dup
        if expires_in
          claims['exp'] = Time.now.to_i + expires_in.to_i
          claims['iat'] = Time.now.to_i
        end
        JWT.encode(claims, sign_key, algorithm, extra_headers).__await__
      end

      private

      def extract_bearer_token
        header = request.env['HTTP_AUTHORIZATION']
        return nil if header.nil? || header.empty?

        # Match "Bearer <token>" — case-insensitive scheme, exactly one
        # space. Guards against "Basic" headers sneaking in.
        parts = header.split(' ', 2)
        return nil unless parts.length == 2 && parts[0].downcase == 'bearer'

        # Also treat a whitespace-only token as missing so authenticate!
        # reports "missing bearer token" instead of falling through to
        # JWT.decode and surfacing a confusing "invalid token" error.
        token = parts[1].strip
        return nil if token.empty?

        token
      end

      def halt_unauthorized!(reason)
        content_type 'application/json'
        halt 401, { 'error' => 'unauthorized', 'reason' => reason }.to_json
      end
    end

    # Default settings — can be overridden via `set :jwt_secret, ...`
    # at the App class level. We don't register the secret ourselves so
    # a missing config trips a loud NoMethodError on first use.
    def self.registered(app)
      app.helpers Helpers
      app.set :jwt_algorithm, 'HS256' unless app.respond_to?(:jwt_algorithm)
    end
  end

  # Keep the canonical Sinatra::register-from-everywhere idiom alive.
  Base.register JwtAuth if defined?(::Sinatra::Base)
end

require 'homura/runtime/async_registry'

HomuraRuntime::AsyncRegistry.register_async_source do
  async_helper :authenticate!, 'Sinatra::JwtAuth'
  async_helper :authenticate_or_401, 'Sinatra::JwtAuth'
  async_helper :issue_token, 'Sinatra::JwtAuth'
end
