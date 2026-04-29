# frozen_string_literal: true

module Sinatra
  module Inertia
    # Wrappers that mark props with Inertia v2 transport modes. They are
    # plain value objects with a Proc payload; resolution happens inside
    # PropsResolver (which knows whether the current request is a partial
    # reload, what component it targets, what fields are requested, etc.).
    #
    # Usage:
    #   inertia 'Page', props: {
    #     todos:  -> { Todo.all },                # plain lazy: included by default, resolved on demand
    #     stats:  Inertia.defer { compute_stats } # excluded from initial response, fetched in 2nd request
    #     csrf:   Inertia.always { csrf_token }   # included even on partial reloads that omit it
    #     filter: Inertia.optional { params[:f] } # only included when explicitly requested via partial
    #     feed:   Inertia.merge(page_items)       # array merged with existing client-side feed
    #     once:   Inertia.once { current_time }   # delivered exactly once; subsequent visits suppress
    #   }
    class Prop
      attr_reader :block, :value, :group

      def initialize(block: nil, value: nil, group: 'default')
        @block = block
        @value = value
        @group = group
      end

      def resolve
        block ? block.call : value
      end

      # Should this prop be included in *every* response (including partials
      # that did not request it)?
      def always? = false

      # Is the value sent in the initial response, or deferred to a second
      # roundtrip?
      def deferred? = false

      # Is this prop only included when explicitly requested via
      # X-Inertia-Partial-Data?
      def optional? = false

      # Should arrays returned by this prop be merged with the client's
      # existing array (Inertia 2 merge semantics)?
      def merge? = false

      # Once-only delivery (cleared from session/state after first emission).
      def once? = false
    end

    class AlwaysProp < Prop
      def always? = true
    end

    class DeferredProp < Prop
      def deferred? = true
    end

    class OptionalProp < Prop
      def optional? = true
    end

    class LazyProp < Prop
      # `lazy` is the historical Inertia 1 alias of `optional`. Kept so
      # existing code reads naturally.
      def optional? = true
    end

    class MergeProp < Prop
      def merge? = true
    end

    module_function

    def always(value = nil, &block) = AlwaysProp.new(block: block, value: value)
    def defer(group: 'default', &block) = DeferredProp.new(block: block, group: group)
    def optional(&block) = OptionalProp.new(block: block)
    def lazy(&block) = LazyProp.new(block: block)
    def merge(value = nil, &block) = MergeProp.new(block: block, value: value)
  end
end
