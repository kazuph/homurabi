# frozen_string_literal: true
# await: true
#
# homura patch: adapted from ruby-jwt v2.9.3 decode.rb.
#
# Every algorithm's verify() for non-HMAC algos returns a Promise (Web
# Crypto subtle). Because Opal's `Enumerable#any?` evaluates the block
# synchronously in JS, we cannot use `allowed_and_valid_algorithms.any?
# { |a| a.verify(...) }` with an async body — the Promise would be
# treated as truthy regardless of the actual verification outcome.
# Instead we iterate with an explicit `while` loop so every `.__await__`
# is resolved before the next iteration.
#
# X5C cert-chain verification is out of scope on Workers (no
# OpenSSL::X509 in our vendor); we raise a clear error if callers pass
# `x5c:` options instead of silently ignoring them.

require 'json'

module JWT
  class Decode
    def initialize(jwt, key, verify, options, &keyfinder)
      raise JWT::DecodeError, 'Nil JSON web token' unless jwt

      @jwt = jwt
      @key = key
      @options = options
      @segments = jwt.split('.')
      @verify = verify
      @signature = ''
      @keyfinder = keyfinder
    end

    def decode_segments
      validate_segment_count!
      if @verify
        decode_signature
        verify_algo
        set_key
        # homura patch: verify_signature is async (contains .__await__
        # to resolve subtle-backed verify Promises). Without an explicit
        # await here, decode_segments would fall through while the
        # rejection fires out-of-band as an UnhandledPromiseRejection,
        # effectively bypassing verification.
        verify_signature.__await__
        verify_claims
      end
      raise JWT::DecodeError, 'Not enough or too many segments' unless header && payload

      [payload, header]
    end

    private

    # homura patch: explicit while-loops replace Array#any? to await
    # each per-key / per-algorithm verify call sequentially.
    def verify_signature
      return unless @key || @verify
      return if none_algorithm?

      raise JWT::DecodeError, 'No verification key available' unless @key

      keys = Array(@key)
      i = 0
      while i < keys.length
        return if verify_signature_for?(keys[i]).__await__

        i += 1
      end

      raise JWT::VerificationError, 'Signature verification failed'
    end

    def verify_algo
      raise JWT::IncorrectAlgorithm, 'An algorithm must be specified' if allowed_algorithms.empty?
      raise JWT::DecodeError, 'Token header not a JSON object' unless header.is_a?(Hash)
      raise JWT::IncorrectAlgorithm, 'Token is missing alg header' unless alg_in_header
      raise JWT::IncorrectAlgorithm, 'Expected a different algorithm' if allowed_and_valid_algorithms.empty?
    end

    def set_key
      @key = find_key(&@keyfinder) if @keyfinder
      @key = ::JWT::JWK::KeyFinder.new(jwks: @options[:jwks], allow_nil_kid: @options[:allow_nil_kid]).key_for(header['kid']) if @options[:jwks]

      # homura patch: x5c verification not supported.
      return unless @options[:x5c]

      raise JWT::DecodeError, 'x5c verification is not supported in the homura jwt vendor'
    end

    # homura patch: explicit while-loop so `.__await__` can sequence
    # subtle verify Promises.
    def verify_signature_for?(key)
      algs = allowed_and_valid_algorithms
      i = 0
      while i < algs.length
        result = algs[i].verify(data: signing_input, signature: @signature, verification_key: key)
        return true if result.__await__

        i += 1
      end
      false
    end

    def allowed_and_valid_algorithms
      @allowed_and_valid_algorithms ||= allowed_algorithms.select { |alg| alg.valid_alg?(alg_in_header) }
    end

    ALGORITHM_KEYS = ['algorithm',
                      :algorithm,
                      'algorithms',
                      :algorithms].freeze

    def given_algorithms
      ALGORITHM_KEYS.each do |alg_key|
        alg = @options[alg_key]
        return Array(alg) if alg
      end
      []
    end

    def allowed_algorithms
      @allowed_algorithms ||= resolve_allowed_algorithms
    end

    def resolve_allowed_algorithms
      algs = given_algorithms.map { |alg| JWA.resolve(alg) }
      sort_by_alg_header(algs)
    end

    def sort_by_alg_header(algs)
      return algs if algs.size <= 1

      algs.partition { |alg| alg.valid_alg?(alg_in_header) }.flatten
    end

    def find_key(&keyfinder)
      key = (keyfinder.arity == 2 ? yield(header, payload) : yield(header))
      return key if key && !Array(key).empty?

      raise JWT::DecodeError, 'No verification key available'
    end

    def verify_claims
      Claims::DecodeVerifier.verify!(payload, @options)
    end

    def validate_segment_count!
      return if segment_length == 3
      return if !@verify && segment_length == 2
      return if segment_length == 2 && none_algorithm?

      raise JWT::DecodeError, 'Not enough or too many segments'
    end

    def segment_length
      @segments.count
    end

    def none_algorithm?
      alg_in_header == 'none'
    end

    def decode_signature
      @signature = ::JWT::Base64.url_decode(@segments[2] || '')
    end

    def alg_in_header
      header['alg']
    end

    def header
      @header ||= parse_and_decode @segments[0]
    end

    def payload
      @payload ||= parse_and_decode @segments[1]
    end

    def signing_input
      @segments.first(2).join('.')
    end

    def parse_and_decode(segment)
      JWT::JSON.parse(::JWT::Base64.url_decode(segment))
    rescue ::JSON::ParserError
      raise JWT::DecodeError, 'Invalid segment encoding'
    end
  end
end
