# frozen_string_literal: true
# await: true
#
# homura patch: replacement for ruby-jwt v2.9.3 eddsa.rb. Upstream
# requires RbNaCl (libsodium) and expects the caller to pass an
# `RbNaCl::Signatures::Ed25519::{Signing,Verify}Key`. On Workers we have
# no libsodium — Phase 7 implements EdDSA via Web Crypto subtle's
# 'Ed25519' algorithm behind `OpenSSL::PKey::Ed25519`. So this file
# accepts `OpenSSL::PKey::Ed25519` keys and routes sign/verify through
# them, with the usual `.__await__` at the subtle boundary.
#
# Both JWT alg names ("ED25519" and "EdDSA") are registered so existing
# JWT tokens interoperate unchanged.

module JWT
  module JWA
    class Eddsa
      include JWT::JWA::SigningAlgorithm

      def initialize(alg)
        @alg = alg
      end

      def sign(data:, signing_key:)
        unless signing_key.is_a?(::OpenSSL::PKey::Ed25519)
          raise_sign_error!("Key given is a #{signing_key.class} but has to be an OpenSSL::PKey::Ed25519")
        end

        # homura patch: `.__await__`. Ed25519#sign takes (digest_or_nil,
        # data); Ed25519 applies SHA-512 internally so the digest arg is
        # ignored — we pass nil.
        signing_key.sign(nil, data).__await__
      end

      def verify(data:, signature:, verification_key:)
        unless verification_key.is_a?(::OpenSSL::PKey::Ed25519)
          raise_verify_error!("Key given is a #{verification_key.class} but has to be an OpenSSL::PKey::Ed25519")
        end

        # homura patch: `.__await__`. Returns bool directly from subtle.
        verification_key.verify(nil, signature, data).__await__
      end

      register_algorithm(new('ED25519'))
      register_algorithm(new('EdDSA'))
    end
  end
end
