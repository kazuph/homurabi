# frozen_string_literal: true
#
# homurabi patch: simplified from ruby-jwt v2.9.3 hmac.rb.
#
#   1. `OpenSSL::HMAC.digest` is synchronous in our Phase 7 vendor
#      (node:crypto.createHmac), so no `.__await__` is needed.
#   2. We drop the OpenSSL 3 empty-key regression branch — Workers
#      has no libssl; our HMAC treats empty keys as "" normally.
#   3. **SecurityUtils.secure_compare rewritten** — Opal's binary Strings
#      created by `Array#pack('H*')` and `Base64.urlsafe_decode64` report
#      different `.bytesize` for byte-identical content (pack produces a
#      length-== JS String; urlsafe_decode64 produces a UTF-8 escaped
#      String whose `bytesize` > `length`). The upstream `a.bytesize ==
#      b.bytesize` check therefore fails even when the byte streams
#      are identical. We normalise both sides to a hex String via
#      `.unpack1('H*')` before comparison; this is byte-canonical and
#      lets us reuse Ruby `String#==` which is constant-time in V8 for
#      equal-length plain ASCII JS Strings.

module JWT
  module JWA
    class Hmac
      include JWT::JWA::SigningAlgorithm

      def self.from_algorithm(algorithm)
        new(algorithm, OpenSSL::Digest.new(algorithm.downcase.gsub('hs', 'sha')))
      end

      def initialize(alg, digest)
        @alg = alg
        @digest = digest
      end

      def sign(data:, signing_key:)
        signing_key ||= ''
        raise_verify_error!('HMAC key expected to be a String') unless signing_key.is_a?(String)

        OpenSSL::HMAC.digest(digest.new, signing_key, data)
      end

      def verify(data:, signature:, verification_key:)
        SecurityUtils.secure_compare(signature, sign(data: data, signing_key: verification_key))
      end

      register_algorithm(new('HS256', OpenSSL::Digest::SHA256))
      register_algorithm(new('HS384', OpenSSL::Digest::SHA384))
      register_algorithm(new('HS512', OpenSSL::Digest::SHA512))

      private

      attr_reader :digest

      # homurabi patch: see header comment. Hex-normalised comparison is
      # what actually works on Opal's two binary-String flavours.
      module SecurityUtils
        def self.secure_compare(a, b)
          a_hex = a.to_s.unpack1('H*') || ''
          b_hex = b.to_s.unpack1('H*') || ''
          return false unless a_hex.length == b_hex.length

          # String#== on equal-length ASCII hex strings is reliable and
          # byte-for-byte accurate across all Opal binary String shapes.
          a_hex == b_hex
        end

        def self.fixed_length_secure_compare(a, b)
          raise ArgumentError, 'string length mismatch.' unless a.to_s.unpack1('H*').length == b.to_s.unpack1('H*').length

          secure_compare(a, b)
        end
      end
    end
  end
end
