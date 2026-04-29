# frozen_string_literal: true

require 'set'

module HomuraRuntime
  class AsyncRegistry
    class Builder
      def initialize(registry)
        @registry = registry
      end

      def async_class(class_name, except: [:new])
        @registry.async_classes[class_name] = except.to_set
      end

      def async_method(class_name, method_name)
        (@registry.async_methods[class_name] ||= Set.new) << method_name
      end

      def async_factory(class_name, method_name)
        (@registry.async_factories[class_name] ||= Set.new) << method_name
      end

      def taint_return(class_name, method_name, return_class_name)
        (@registry.taint_returns[class_name] ||= {})[method_name] = return_class_name
      end

      def async_accessor(lvar_name, accessor_name, class_name)
        @registry.async_accessors[[lvar_name.to_sym, accessor_name.to_sym]] = class_name
      end

      def async_helper(method_name, class_name)
        (@registry.async_helpers[method_name.to_sym] ||= Set.new) << class_name
      end

      def helper_factory(method_name, class_name)
        @registry.helper_factories[method_name.to_sym] = class_name
      end
    end

    class << self
      def register_async_source(&block)
        builder = Builder.new(instance)
        builder.instance_eval(&block)
      end

      def instance
        @instance ||= new
      end

      def reset!
        @instance = new
      end

      def async?(class_name, method_name)
        instance.async?(class_name, method_name)
      end

      def factory?(class_name, method_name)
        instance.factory?(class_name, method_name)
      end

      def taint_return_class(class_name, method_name)
        instance.taint_return_class(class_name, method_name)
      end

      def tainted_class?(class_name)
        instance.tainted_class?(class_name)
      end

      def auto_load_gem_async_sources(debug: false)
        return unless defined?(Gem) && Gem.respond_to?(:loaded_specs)

        loaded = 0
        Gem.loaded_specs.each_value do |spec|
          next if spec.full_gem_path.nil?

          lib_dir = File.join(spec.full_gem_path, 'lib')
          next unless Dir.exist?(lib_dir)

          Dir.glob(File.join(lib_dir, '**', '*.rb')).each do |path|
            next unless File.read(path).include?('register_async_source')

            require_path = path.sub(Regexp.new("^#{Regexp.escape(lib_dir)}/"), '').sub(/\.rb\z/, '')
            begin
              require require_path
              loaded += 1
              puts "[auto-await] loaded async source from #{spec.name}: #{require_path}" if debug
            rescue LoadError, StandardError => e
              warn "[auto-await] Warning: failed to load async source from #{spec.name}/#{require_path}: #{e.message}" if debug
            end
          end
        end

        puts "[auto-await] auto-loaded #{loaded} async source file(s)" if debug && loaded.positive?
      end
    end

    attr_reader :async_classes, :async_methods, :async_factories, :taint_returns, :async_accessors, :async_helpers, :helper_factories

    def initialize
      @async_classes = {}
      @async_methods = {}
      @async_factories = {}
      @taint_returns = {}
      @async_accessors = {}
      @async_helpers = {}
      @helper_factories = {}
    end

    def async?(class_name, method_name)
      return false if method_name == :new
      methods = @async_methods[class_name]
      return true if methods&.include?(method_name)
      except = @async_classes[class_name]
      return true if except && !except.include?(method_name.to_s) && !except.include?(method_name.to_sym)
      false
    end

    def factory?(class_name, method_name)
      @async_factories[class_name]&.include?(method_name)
    end

    def taint_return_class(class_name, method_name)
      @taint_returns[class_name]&.[](method_name)
    end

    def tainted_class?(class_name)
      @async_classes.key?(class_name) ||
        @async_methods.key?(class_name) ||
        @async_factories.key?(class_name) ||
        @taint_returns.key?(class_name)
    end
  end
end

# Phase 17.5 — Auto-Await: register runtime gem async sources.
# Each binding declares which methods return Promises so the
# build-time analyzer can insert .__await__ automatically.
HomuraRuntime::AsyncRegistry.register_async_source do
  async_method 'Cloudflare::D1Database', :execute
  async_method 'Cloudflare::D1Database', :get_first_row
  async_method 'Cloudflare::D1Database', :execute_insert
  async_method 'Cloudflare::D1Database', :execute_batch
  taint_return 'Cloudflare::D1Database', :prepare, 'Cloudflare::D1Statement'
  taint_return 'Cloudflare::D1Database', :[], 'Cloudflare::D1Statement'

  async_method 'Cloudflare::D1Statement', :all
  async_method 'Cloudflare::D1Statement', :first
  async_method 'Cloudflare::D1Statement', :run
  # `bind` returns a new D1Statement for further chaining. Tainting the
  # return preserves the type so the auto-await pass keeps chaining
  # `.run` / `.all` / `.first` on the bound statement (otherwise
  # `db.prepare(sql).bind(...).run` drops await on `.run` and
  # `flatten_meta` ends up receiving a JS Promise instead of the
  # metadata Hash).
  taint_return 'Cloudflare::D1Statement', :bind, 'Cloudflare::D1Statement'

  async_method 'Cloudflare::KVNamespace', :get
  async_method 'Cloudflare::KVNamespace', :get_with_metadata
  async_method 'Cloudflare::KVNamespace', :put
  async_method 'Cloudflare::KVNamespace', :delete
  async_method 'Cloudflare::KVNamespace', :list

  async_method 'Cloudflare::R2Bucket', :get
  async_method 'Cloudflare::R2Bucket', :get_binary
  async_method 'Cloudflare::R2Bucket', :put
  async_method 'Cloudflare::R2Bucket', :delete
  async_method 'Cloudflare::R2Bucket', :list
  async_method 'Cloudflare::R2Bucket', :head

  async_method 'Cloudflare::AI', :run
  taint_return 'Cloudflare::AI', :run_stream, 'Cloudflare::AI::Stream'

  async_method 'Cloudflare::Cache', :match
  async_method 'Cloudflare::Cache', :put
  async_method 'Cloudflare::Cache', :delete

  async_factory 'Cloudflare::Email', :new
  async_method 'Cloudflare::Email', :send

  async_method 'Cloudflare::Queue', :send
  async_method 'Cloudflare::Queue', :send_batch

  async_factory 'Cloudflare::DurableObjectNamespace', :new
  taint_return 'Cloudflare::DurableObjectNamespace', :get, 'Cloudflare::DurableObjectStub'
  taint_return 'Cloudflare::DurableObjectNamespace', :get_by_name, 'Cloudflare::DurableObjectStub'
  taint_return 'Cloudflare::DurableObjectState', :storage, 'Cloudflare::DurableObjectStorage'
  async_method 'Cloudflare::DurableObjectStub', :fetch

  async_method 'Cloudflare::DurableObjectStorage', :get
  async_method 'Cloudflare::DurableObjectStorage', :put
  async_method 'Cloudflare::DurableObjectStorage', :delete
  async_method 'Cloudflare::DurableObjectStorage', :list
  async_method 'Cloudflare::DurableObjectStorage', :transaction

  async_method 'Cloudflare::HTTP', :fetch

  async_method 'Faraday::Connection', :get
  async_method 'Faraday::Connection', :post
  async_method 'Faraday::Connection', :put
  async_method 'Faraday::Connection', :delete
  async_method 'Faraday::Connection', :patch
  async_method 'Faraday::Connection', :head
end
