# frozen_string_literal: true
# await: true
#
# homurabi patch: adapted from ruby-jwt v2.9.3 ps.rb. Phase 7 RSA-PSS hits
# Web Crypto subtle → Promise. Adds `.__await__` at the boundary.
#
# Upstream uses salt_length: :auto for verify, which Web Crypto subtle
# does not support; we use :digest (RFC 7518 recommendation for JWT).
# This still interoperates with CRuby-generated JWT PS tokens because
# every spec-compliant PSS JWT fixes salt length to the digest byte size.

module JWT
  module JWA
    class Ps
      include JWT::JWA::SigningAlgorithm

      def initialize(alg)
        @alg = alg
        @digest_algorithm = alg.sub('PS', 'sha')
      end

      def sign(data:, signing_key:)
        unless signing_key.is_a?(::OpenSSL::PKey::RSA)
          raise_sign_error!("The given key is a #{signing_key.class}. It has to be an OpenSSL::PKey::RSA instance.")
        end

        # homurabi patch: `.__await__`. salt_length: :digest is fixed here
        # (JWT spec) rather than :auto (not representable in Web Crypto).
        signing_key.sign_pss(digest_algorithm, data,
                             salt_length: :digest,
                             mgf1_hash: digest_algorithm).__await__
      end

      def verify(data:, signature:, verification_key:)
        # homurabi patch: `.__await__`. salt_length: :digest (see sign).
        verification_key.verify_pss(digest_algorithm, signature, data,
                                    salt_length: :digest,
                                    mgf1_hash: digest_algorithm).__await__
      rescue OpenSSL::PKey::PKeyError
        raise JWT::VerificationError, 'Signature verification raised'
      end

      register_algorithm(new('PS256'))
      register_algorithm(new('PS384'))
      register_algorithm(new('PS512'))

      private

      attr_reader :digest_algorithm
    end
  end
end
