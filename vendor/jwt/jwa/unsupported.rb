# frozen_string_literal: true
#
# homurabi patch: verbatim from ruby-jwt v2.9.3.

module JWT
  module JWA
    module Unsupported
      class << self
        include JWT::JWA::SigningAlgorithm

        def sign(*)
          raise_sign_error!('Unsupported signing method')
        end

        def verify(*)
          raise JWT::VerificationError, 'Algorithm not supported'
        end
      end
    end
  end
end
