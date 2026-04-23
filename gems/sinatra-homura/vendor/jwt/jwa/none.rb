# frozen_string_literal: true
#
# homura patch: verbatim from ruby-jwt v2.9.3.

module JWT
  module JWA
    class None
      include JWT::JWA::SigningAlgorithm

      def initialize
        @alg = 'none'
      end

      def sign(*)
        ''
      end

      def verify(*)
        true
      end

      register_algorithm(new)
    end
  end
end
