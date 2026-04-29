# frozen_string_literal: true

require_relative 'deferred'

module Sinatra
  module Inertia
    # Builds the Inertia page object from a (component, props, request)
    # tuple, applying partial-reload selection, deferred-prop excision,
    # merge/once metadata, encrypted history flags, etc.
    #
    # The output is a Hash that gets serialized as JSON for X-Inertia
    # responses, or interpolated into the layout's `data-page` attribute
    # for full HTML responses.
    class Response
      attr_reader :component, :props, :request, :version, :url,
                  :encrypt_history, :clear_history, :shared, :errors

      def initialize(component:, props:, request:, version:, url: nil,
                     encrypt_history: false, clear_history: false,
                     shared: {}, errors: nil)
        @component = component
        @props = props || {}
        @request = request
        @version = version.to_s
        @url = url || request.fullpath
        @encrypt_history = encrypt_history
        @clear_history = clear_history
        @shared = shared || {}
        @errors = errors
      end

      def to_h
        merged_props = deep_merge(shared, props)
        merged_props = merged_props.merge(errors: errors) if errors

        partial = partial_request?
        partial_data = partial_data_keys
        partial_except = partial_except_keys
        reset = reset_keys

        resolved = {}
        deferred_groups = {}
        merge_keys = []

        # NOTE: avoid block-based iteration here. On Opal, when this
        # method runs as `async function` (because `await_if_promise`
        # awaits a JS Promise), inner blocks like `Hash#each { ... }`
        # do not natively suspend the outer function until the block
        # body's awaits complete. A plain index-based loop preserves
        # ordering and lets each iteration's `__await__` properly
        # gate the next.
        keys = merged_props.keys
        i = 0
        while i < keys.length
          key = keys[i]
          value = merged_props[key]
          k = key.to_sym
          included, materialized = decide(value, k, partial, partial_data, partial_except)
          if included
            resolved[k] = await_if_promise(materialized)
            if value.is_a?(Prop) && value.merge? && !reset.include?(k)
              merge_keys << k.to_s
            end
          elsif value.is_a?(Prop) && value.deferred?
            (deferred_groups[value.group] ||= []) << k.to_s
          end
          i += 1
        end

        page = {
          component: component,
          props: resolved,
          url: url,
          version: version
        }
        page[:encryptHistory] = true if encrypt_history
        page[:clearHistory] = true if clear_history
        page[:deferredProps] = deferred_groups unless deferred_groups.empty?
        page[:mergeProps] = merge_keys unless merge_keys.empty?
        page
      end

      def to_json(*) = to_h.to_json

      private

      def partial_request?
        request.env['HTTP_X_INERTIA_PARTIAL_COMPONENT'] == component
      end

      def partial_data_keys
        raw = request.env['HTTP_X_INERTIA_PARTIAL_DATA'].to_s
        return nil if raw.empty?
        raw.split(',').map(&:strip).reject(&:empty?).map(&:to_sym)
      end

      def partial_except_keys
        raw = request.env['HTTP_X_INERTIA_PARTIAL_EXCEPT'].to_s
        return nil if raw.empty?
        raw.split(',').map(&:strip).reject(&:empty?).map(&:to_sym)
      end

      # Inertia 2.0: `X-Inertia-Reset: a,b` tells the server "the client
      # wants merge prop `a` and `b` to be replaced wholesale, not
      # appended". We honour it by dropping the named keys from the
      # outbound `mergeProps` array — the value itself is still resolved
      # and emitted, so the client just doesn't accumulate it.
      def reset_keys
        raw = request.env['HTTP_X_INERTIA_RESET'].to_s
        return [] if raw.empty?
        raw.split(',').map(&:strip).reject(&:empty?).map(&:to_sym)
      end

      # Returns [included?, resolved_value]
      def decide(value, key, partial, partial_data, partial_except)
        if value.is_a?(Prop)
          if value.always?
            return [true, value.resolve]
          elsif value.deferred?
            return [false, nil] unless partial && partial_data&.include?(key)
            return [true, value.resolve]
          elsif value.optional?
            return [false, nil] unless partial && partial_data&.include?(key)
            return [true, value.resolve]
          else
            # merge / once / plain Prop
            if partial
              return [false, nil] if partial_data && !partial_data.include?(key)
              return [false, nil] if partial_except&.include?(key)
            end
            return [true, value.resolve]
          end
        end

        if value.is_a?(Proc)
          # A bare Proc/Lambda is treated as plain lazy: resolved every
          # request, but only when included.
          if partial
            return [false, nil] if partial_data && !partial_data.include?(key)
            return [false, nil] if partial_except&.include?(key)
          end
          return [true, value.call]
        end

        # Plain value
        if partial
          return [false, nil] if partial_data && !partial_data.include?(key)
          return [false, nil] if partial_except&.include?(key)
        end
        [true, value]
      end

      def deep_merge(a, b)
        a.merge(b) do |_k, av, bv|
          if av.is_a?(Hash) && bv.is_a?(Hash)
            deep_merge(av, bv)
          else
            bv
          end
        end
      end

      # When running on the homura Cloudflare Workers / Opal runtime, a Proc
      # may return a JS Promise (e.g. a sequel-d1 query result). The
      # surrounding route handler is already an async function thanks to
      # homura's auto-await analyzer, so we can resolve the Promise here
      # via `.__await__`. On MRI this branch is dead code (no Cloudflare
      # constant, no js_promise?), so plain Ruby tests are unaffected.
      def await_if_promise(value)
        if defined?(::Cloudflare) && ::Cloudflare.respond_to?(:js_promise?) && ::Cloudflare.js_promise?(value)
          value.__await__
        else
          value
        end
      end
    end
  end
end
