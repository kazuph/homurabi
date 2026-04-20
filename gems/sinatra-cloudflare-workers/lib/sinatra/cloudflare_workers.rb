# frozen_string_literal: true

# Entry point for Sinatra-on-Cloudflare-Workers (Opal) apps.
# Require this before defining routes so Opal patches and extensions load first.
#
# Order: runtime (Cloudflare::BinaryBody, Rack handler) → Opal/Sinatra patches → Sinatra::Base → extensions.

require 'cloudflare_workers'
require 'sinatra_opal_patches'
require 'sinatra/base'

require 'sinatra/jwt_auth'
require 'sinatra/scheduled'
require 'sinatra/queue'

module Sinatra
  module CloudflareWorkers
    # If the user forgot `run App` but defined a top-level App < Sinatra::Base,
    # register the Rack handler once at process teardown (Worker isolate load).
    def self.ensure_rack_app!
      return unless defined?(Rack::Handler::CloudflareWorkers)

      existing = Rack::Handler::CloudflareWorkers.app
      return existing if existing

      return unless Object.const_defined?(:App, false)

      app = Object.const_get(:App)
      return unless app.is_a?(Class) && app < Sinatra::Base

      Rack::Handler::CloudflareWorkers.run(app)
    end
  end
end

at_exit { Sinatra::CloudflareWorkers.ensure_rack_app! }
