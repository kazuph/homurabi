# frozen_string_literal: true
#
# homurabi patch: stub of ruby-jwt v2.9.3 jwk.rb. Upstream exposes
# `JWT::JWK.create_from` / `JWT::JWK::KeyFinder` which need full
# OpenSSL::PKey::EC / RSA JWK serializers (n/e/d/p/q/dp/dq/qi,
# crv/x/y/d, etc.) — a non-trivial vendoring effort beyond what Phase 8
# requires. The Sinatra helper we ship uses plain keys, not JWKS. This
# stub keeps the `require 'jwt/jwk'` chain happy and surfaces a clear
# error if user code actually calls into the JWK machinery.

module JWT
  module JWK
    class << self
      def create_from(*)
        raise JWT::JWKError,
              'JWK support is not enabled in the homurabi jwt vendor (Phase 8). ' \
              'Use plain OpenSSL::PKey::* keys with JWT.encode / JWT.decode.'
      end

      alias new create_from
      alias import create_from
    end

    class KeyFinder
      def initialize(*)
        raise JWT::JWKError,
              'JWKS key finder is not enabled in the homurabi jwt vendor (Phase 8).'
      end
    end
  end
end
