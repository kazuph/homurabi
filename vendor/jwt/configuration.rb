# frozen_string_literal: true
#
# homurabi patch: verbatim from ruby-jwt v2.9.3 configuration.rb. The
# container loads DecodeConfiguration + a stubbed JwkConfiguration (since
# Opal has no deep dup for kid generators).

require 'jwt/configuration/container'

module JWT
  module Configuration
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= ::JWT::Configuration::Container.new
    end
  end
end
