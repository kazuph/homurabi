# frozen_string_literal: true
#
# homurabi patch: stub of JwkConfiguration. The upstream version eagerly
# loads JWT::JWK::KidAsKeyDigest / Thumbprint, which pull in OpenSSL::Digest
# and a full DER-encoded fingerprint path we don't need for plain JWT
# encode/decode. This stub preserves the `kid_generator` interface (readable
# and writable attribute) so callers that set `JWT.configuration.jwk
# .kid_generator = MyCustomClass` still work on Workers.

module JWT
  module Configuration
    class JwkConfiguration
      attr_accessor :kid_generator

      def initialize
        @kid_generator = nil
      end

      def kid_generator_type=(_value)
        raise NotImplementedError,
              'JWK key fingerprinting is not enabled in the homurabi jwt vendor. ' \
              'Assign a custom kid_generator directly if you need thumbprints.'
      end
    end
  end
end
