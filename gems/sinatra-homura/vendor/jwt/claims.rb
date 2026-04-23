# frozen_string_literal: true
#
# homura patch: verbatim structure from ruby-jwt v2.9.3 claims.rb.

require 'jwt/claims/audience'
require 'jwt/claims/expiration'
require 'jwt/claims/issued_at'
require 'jwt/claims/issuer'
require 'jwt/claims/jwt_id'
require 'jwt/claims/not_before'
require 'jwt/claims/numeric'
require 'jwt/claims/required'
require 'jwt/claims/subject'
require 'jwt/claims/decode_verifier'
require 'jwt/claims/verifier'

module JWT
  module Claims
    Error = Struct.new(:message, keyword_init: true)

    class << self
      def verify!(payload, options)
        DecodeVerifier.verify!(payload, options)
      end

      def verify_payload!(payload, *options)
        verify_token!(VerificationContext.new(payload: payload), *options)
      end

      def valid_payload?(payload, *options)
        payload_errors(payload, *options).empty?
      end

      def payload_errors(payload, *options)
        token_errors(VerificationContext.new(payload: payload), *options)
      end

      private

      def verify_token!(token, *options)
        Verifier.verify!(token, *options)
      end

      def token_errors(token, *options)
        Verifier.errors(token, *options)
      end
    end
  end
end
