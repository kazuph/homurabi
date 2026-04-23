# frozen_string_literal: true
# await: true
#
# homura patch: adapted from ruby-jwt v2.9.3 ecdsa.rb. Upstream goes
# through `signing_key.dsa_sign_asn1(digest.digest(data))` to get a DER
# signature, then converts DER→raw R||S by hand via OpenSSL::ASN1. On
# Workers we short-circuit: Web Crypto subtle's `ECDSA` sign already
# produces raw R||S directly — the exact JWT wire format — so we call
# `OpenSSL::PKey::EC#sign_jwt` / `#verify_jwt` and skip the ASN1 detour
# entirely. That saves us from vendoring OpenSSL::ASN1.
#
# The JWT spec allows ES256 (P-256/SHA-256), ES384 (P-384/SHA-384),
# ES512 (P-521/SHA-512). ES256K (secp256k1) is NOT in Web Crypto subtle
# and is therefore not supported here.

module JWT
  module JWA
    class Ecdsa
      include JWT::JWA::SigningAlgorithm

      NAMED_CURVES = {
        'prime256v1' => { algorithm: 'ES256', digest: 'sha256' },
        'secp256r1'  => { algorithm: 'ES256', digest: 'sha256' }, # alias
        'secp384r1'  => { algorithm: 'ES384', digest: 'sha384' },
        'secp521r1'  => { algorithm: 'ES512', digest: 'sha512' }
        # homura note: ES256K (secp256k1) intentionally omitted — not in
        # the Web Crypto spec and not implementable through subtle.
      }.freeze

      def initialize(alg, digest)
        @alg = alg
        @digest = OpenSSL::Digest.new(digest)
      end

      def sign(data:, signing_key:)
        check_curve!(signing_key)
        # homura patch: `.__await__`. sign_jwt returns raw R||S directly
        # — the JWT wire format — so no DER conversion is needed.
        signing_key.sign_jwt(digest, data).__await__
      end

      def verify(data:, signature:, verification_key:)
        check_curve!(verification_key)
        # homura patch: `.__await__`. verify_jwt accepts raw R||S.
        verification_key.verify_jwt(digest, signature, data).__await__
      rescue OpenSSL::PKey::PKeyError
        raise JWT::VerificationError, 'Signature verification raised'
      end

      NAMED_CURVES.each_value do |v|
        register_algorithm(new(v[:algorithm], v[:digest]))
      end

      def self.from_algorithm(algorithm)
        new(algorithm, algorithm.downcase.gsub('es', 'sha'))
      end

      def self.curve_by_name(name)
        NAMED_CURVES.fetch(name) do
          raise UnsupportedEcdsaCurve, "The ECDSA curve '#{name}' is not supported"
        end
      end

      private

      attr_reader :digest

      def check_curve!(key)
        curve_definition = self.class.curve_by_name(key.group.curve_name)
        key_algorithm = curve_definition[:algorithm]
        return if alg == key_algorithm

        raise IncorrectAlgorithm,
              "payload algorithm is #{alg} but #{key_algorithm} signing key was provided"
      end
    end
  end
end
