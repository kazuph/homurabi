# frozen_string_literal: true

# Cloudflare-Workers-side glue for Sinatra. As of sinatra-homura 0.2.23
# this file is loaded *automatically* from the bottom of
# `vendor/sinatra.rb` and `vendor/sinatra/base.rb`, so users no longer
# need an explicit `require 'sinatra/cloudflare_workers'` line. The
# require is still kept around for backward compatibility (a no-op
# second load is fine).
#
# Order: runtime (Cloudflare::BinaryBody, Rack handler) → Opal/Sinatra
# patches → Sinatra::Base → extensions.

require 'cloudflare_workers'
require 'sinatra_opal_patches'
require 'sinatra/base'

require 'sinatra/jwt_auth'
require 'sinatra/scheduled'
require 'sinatra/queue'

module Sinatra
  module CloudflareWorkers
    # Auto-registration shim. The user is allowed (and encouraged) to
    # write the canonical Sinatra snippet from sinatrarb.com:
    #
    #   require 'sinatra'
    #   get '/frank-says' do
    #     'Put this in your pipe & smoke it!'
    #   end
    #
    # …without an explicit `run Sinatra::Application` line. Or the
    # textbook modular form:
    #
    #   require 'sinatra/base'
    #   class App < Sinatra::Base
    #     get '/' do; 'hi'; end
    #   end
    #
    # …without `run App`. This runs at first-fetch time (lazy) — the
    # Workers isolate never actually exits between requests, so the
    # at_exit hook the previous version installed was unreliable.
    # `Rack::Handler::CloudflareWorkers#call` calls back into here when
    # `@app` is nil so we can pick the right Rack app.
    #
    # Resolution order: a user-defined `App` (must be a `Sinatra::Base`
    # subclass with at least one route) wins over the implicit
    # `Sinatra::Application`. If neither has routes, nothing happens —
    # this lets a worker entry-point that *only* exposes
    # `scheduled` / `queue` / `email` handlers boot without an HTTP
    # surface.
    def self.ensure_rack_app!
      return unless defined?(::Rack::Handler::CloudflareWorkers)
      return ::Rack::Handler::CloudflareWorkers.app if ::Rack::Handler::CloudflareWorkers.app

      candidate = pick_modular_app || pick_classic_app
      return unless candidate

      ::Rack::Handler::CloudflareWorkers.run(candidate)
    end

    def self.pick_modular_app
      return nil unless ::Object.const_defined?(:App, false)
      app = ::Object.const_get(:App)
      return nil unless app.is_a?(::Class) && app < ::Sinatra::Base
      return nil unless app_has_routes?(app)
      app
    end

    def self.pick_classic_app
      return nil unless defined?(::Sinatra::Application)
      return nil unless app_has_routes?(::Sinatra::Application)
      ::Sinatra::Application
    end

    def self.app_has_routes?(klass)
      routes = klass.routes
      return false unless routes.respond_to?(:each_value)
      routes.each_value do |entries|
        return true if entries.respond_to?(:any?) && entries.any?
      end
      false
    end
  end
end

# Kept for backward compatibility with code that still wires up at_exit
# explicitly; harmless on Workers because the isolate doesn't exit.
at_exit { Sinatra::CloudflareWorkers.ensure_rack_app! }

# Eagerly boot the JS-side dispatcher so a fetch arriving before
# `run` was called still lands inside
# `Rack::Handler::CloudflareWorkers#call`, where the lazy
# `ensure_rack_app!` discovery kicks in.
Rack::Handler::CloudflareWorkers.ensure_dispatcher_installed! if defined?(Rack::Handler::CloudflareWorkers)
