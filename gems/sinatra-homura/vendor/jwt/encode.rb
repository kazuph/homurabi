# frozen_string_literal: true
# await: true
#
# homura patch: adapted from ruby-jwt v2.9.3 encode.rb.
#
# Algorithm sign() for RS/PS/ES/EdDSA hits Web Crypto subtle through
# OpenSSL::PKey — async in Opal. Any method that transitively calls
# `.__await__` is compiled to a JS async function and returns a Promise;
# callers must `.__await__` it back. We thread awaits through
# `compute_signature` → `encoded_signature` → `segments` so JWT.encode
# exposes a single async surface that resolves to the joined String.
# HS256/384/512 return a plain String — `.__await__` on a non-thenable
# is a no-op, so the same code path serves both sync and async algos.

require 'jwt/jwa'

module JWT
  class Encode
    def initialize(options)
      @payload   = options[:payload]
      @key       = options[:key]
      @algorithm = JWA.resolve(options[:algorithm])
      @headers   = options[:headers].transform_keys(&:to_s)
    end

    def segments
      validate_claims!
      raw_sig = compute_signature.__await__
      encoded_sig = ::JWT::Base64.url_encode(raw_sig)
      combine(encoded_header_and_payload, encoded_sig)
    end

    private

    def encoded_header
      @encoded_header ||= encode_header
    end

    def encoded_payload
      @encoded_payload ||= encode_payload
    end

    def encoded_header_and_payload
      @encoded_header_and_payload ||= combine(encoded_header, encoded_payload)
    end

    def encode_header
      encode_data(@headers.merge(@algorithm.header(signing_key: @key)))
    end

    def encode_payload
      encode_data(@payload)
    end

    # homura patch: returns whatever the algorithm returns — a JS Promise
    # for subtle-backed algos (RS/PS/ES/EdDSA) or a String for HMAC. Caller
    # `.__await__`s the result.
    def compute_signature
      @algorithm.sign(data: encoded_header_and_payload, signing_key: @key)
    end

    def validate_claims!
      return unless @payload.is_a?(Hash)

      Claims.verify_payload!(@payload, :numeric)
    end

    def encode_data(data)
      ::JWT::Base64.url_encode(JWT::JSON.generate(data))
    end

    def combine(*parts)
      parts.join('.')
    end
  end
end
