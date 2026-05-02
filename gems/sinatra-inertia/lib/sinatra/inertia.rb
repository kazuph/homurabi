# frozen_string_literal: true

require 'sinatra/base'
require_relative 'inertia/version'
require_relative 'inertia/errors'
require_relative 'inertia/deferred'
require_relative 'inertia/response'
require_relative 'inertia/middleware'
require_relative 'inertia/csrf_middleware'
require_relative 'inertia/helpers'
require_relative 'inertia/async_sources'

module Sinatra
  # Inertia.js v2 protocol adapter for Sinatra.
  #
  #   class App < Sinatra::Base
  #     register Sinatra::Inertia
  #
  #     set :page_version, -> { ASSETS_VERSION }
  #     set :page_layout,  :layout
  #
  #     share_props do
  #       { auth: { user: current_user }, flash: flash_payload }
  #     end
  #
  #     get '/' do
  #       render 'Todos/Index', todos: -> { Todo.all }
  #     end
  #   end
  #
  # See README.md for the full feature matrix.
  module Inertia
    def self.registered(app)
      # Default settings. `page_*` is the recommended application-facing API;
      # `inertia_*` remains supported for existing apps and lower-level tuning.
      app.set :inertia_version, '1' unless app.respond_to?(:inertia_version)
      app.set :inertia_layout,  :layout unless app.respond_to?(:inertia_layout)
      app.set :inertia_encrypt_history, false unless app.respond_to?(:inertia_encrypt_history)
      app.set :inertia_csrf_protection, true unless app.respond_to?(:inertia_csrf_protection)
      app.set :inertia_share_blocks, []

      # Mount CSRF middleware (double-submit XSRF-TOKEN cookie that
      # @inertiajs/* clients honour). Opt-out via
      # `set :inertia_csrf_protection, false` when the consumer ships
      # its own (e.g. Rack::Protection::AuthenticityToken).
      if app.settings.inertia_csrf_protection
        app.use Sinatra::Inertia::CSRFMiddleware
      end

      # Mount protocol middleware (version mismatch + 303 redirect promotion).
      app.use Sinatra::Inertia::Middleware, version: lambda {
        version = if app.settings.respond_to?(:page_version)
                    app.settings.page_version
                  else
                    app.settings.inertia_version
                  end
        version.respond_to?(:call) ? version.call.to_s : version.to_s
      }

      # Class-level DSL: `share_props { ... }` registers a block whose return
      # value is merged into every page's props.
      app.define_singleton_method(:inertia_share) do |&block|
        raise ArgumentError, 'inertia_share requires a block' unless block
        settings.inertia_share_blocks = settings.inertia_share_blocks + [block]
      end

      app.define_singleton_method(:share_props) do |&block|
        inertia_share(&block)
      end

      app.helpers Sinatra::Inertia::Helpers
    end

    # Convenience module-level constructors so code can write
    #   Inertia.defer { compute }
    # without `Sinatra::` prefix. Defined in deferred.rb.
  end

  register Inertia if respond_to?(:register)
end

# Top-level shortcut so consumers can write `Inertia.defer { ... }` without
# prefixing every prop wrapper with `Sinatra::`. We deliberately do *not*
# overwrite an existing `::Inertia` constant — if your app has one, use
# `Sinatra::Inertia.defer` instead.
::Inertia = Sinatra::Inertia unless defined?(::Inertia)
