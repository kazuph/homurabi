# frozen_string_literal: true
# await: true
#
# homurabi patch: adapted from ruby-jwt v2.9.3 rsa.rb.
# OpenSSL::PKey::RSA#sign / #verify in Phase 7 are backed by Web Crypto
# subtle (`RSASSA-PKCS1-v1_5`), so both return a Promise. We add
# `.__await__` inside the algo class so Encode/Decode can treat the return
# value as a plain String (signature) / bool (verify).

module JWT
  module JWA
    class Rsa
      include JWT::JWA::SigningAlgorithm

      def initialize(alg)
        @alg = alg
        @digest = OpenSSL::Digest.new(alg.sub('RS', 'SHA'))
      end

      def sign(data:, signing_key:)
        unless signing_key.is_a?(OpenSSL::PKey::RSA)
          raise_sign_error!("The given key is a #{signing_key.class}. It has to be an OpenSSL::PKey::RSA instance")
        end

        # homurabi patch: `.__await__` — subtle-backed sign returns Promise.
        signing_key.sign(digest, data).__await__
      end

      def verify(data:, signature:, verification_key:)
        # homurabi patch: `.__await__` — subtle-backed verify returns Promise.
        verification_key.verify(digest, signature, data).__await__
      rescue OpenSSL::PKey::PKeyError
        raise JWT::VerificationError, 'Signature verification raised'
      end

      register_algorithm(new('RS256'))
      register_algorithm(new('RS384'))
      register_algorithm(new('RS512'))

      private

      attr_reader :digest
    end
  end
end
