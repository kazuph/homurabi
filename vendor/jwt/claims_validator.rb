# frozen_string_literal: true
#
# homurabi patch: verbatim from ruby-jwt v2.9.3.

module JWT
  class ClaimsValidator
    def initialize(payload)
      @payload = payload
    end

    def validate!
      Claims.verify_payload!(@payload, :numeric)
      true
    end
  end
end
