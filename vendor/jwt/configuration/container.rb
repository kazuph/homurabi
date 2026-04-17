# frozen_string_literal: true
#
# homurabi patch: from ruby-jwt v2.9.3, with the JwkConfiguration field
# replaced by a stub that never touches OpenSSL::Digest at init time. The
# real upstream container eagerly constructs a KidAsKeyDigest which needs
# OpenSSL::Digest.new('sha256'); we leave that lazy so plain JWT flow
# never pays the init cost.

require 'jwt/configuration/decode_configuration'
require 'jwt/configuration/jwk_configuration'

module JWT
  module Configuration
    class Container
      attr_accessor :decode, :jwk, :strict_base64_decoding
      attr_reader :deprecation_warnings

      def initialize
        reset!
      end

      def reset!
        @decode                 = DecodeConfiguration.new
        @jwk                    = JwkConfiguration.new
        @strict_base64_decoding = false

        self.deprecation_warnings = :once
      end

      DEPRECATION_WARNINGS_VALUES = %i[once warn silent].freeze
      def deprecation_warnings=(value)
        unless DEPRECATION_WARNINGS_VALUES.include?(value)
          raise ArgumentError, "Invalid deprecation_warnings value #{value}. Supported values: #{DEPRECATION_WARNINGS_VALUES}"
        end

        @deprecation_warnings = value
      end
    end
  end
end
