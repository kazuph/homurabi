# frozen_string_literal: true
#
# homurabi patch: adapted from ruby-jwt v2.9.3 jwa.rb. We drop the
# optional `require 'rbnacl'` dance (Workers has no libsodium; our EdDSA
# goes through OpenSSL::PKey::Ed25519 in Phase 7). The EdDSA algo is
# therefore loaded unconditionally from jwa/eddsa.rb.

require 'openssl'

require 'jwt/jwa/compat'
require 'jwt/jwa/signing_algorithm'
require 'jwt/jwa/ecdsa'
require 'jwt/jwa/hmac'
require 'jwt/jwa/none'
require 'jwt/jwa/ps'
require 'jwt/jwa/rsa'
require 'jwt/jwa/eddsa'
require 'jwt/jwa/unsupported'
require 'jwt/jwa/wrapper'

module JWT
  module JWA
    class << self
      def resolve(algorithm)
        return find(algorithm) if algorithm.is_a?(String) || algorithm.is_a?(Symbol)

        unless algorithm.is_a?(SigningAlgorithm)
          Deprecations.warning('Custom algorithms are required to include JWT::JWA::SigningAlgorithm. Custom algorithms that do not include this module may stop working in the next major version of ruby-jwt.')
          return Wrapper.new(algorithm)
        end

        algorithm
      end

      def create(algorithm)
        resolve(algorithm)
      end
    end
  end
end
