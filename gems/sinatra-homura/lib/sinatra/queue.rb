# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Sinatra::Queue
#
# Adds a class-level `consume_queue` DSL so user apps can register
# Cloudflare Queues consumer handlers alongside HTTP routes, matching
# the Phase 9 `schedule` pattern:
#
#     class App < Sinatra::Base
#       register Sinatra::Queue
#
#       consume_queue 'jobs' do |batch|
#         batch.messages.each do |msg|
#           body = msg.body            # Hash / Array / String
#           process(body)
#           msg.ack
#         end
#       end
#     end
#
# The block runs inside a `Cloudflare::QueueContext` so it sees the
# same `db` / `kv` / `bucket` helpers an HTTP route would.
#
# Under the hood, we define the block as a method on QueueContext to
# pick up Opal's `# await: true` async-transform (same reason
# `Sinatra::Scheduled` does it — bare `instance_exec` wouldn't get the
# `__await__` rewrite).

module Sinatra
  module Queue
    module ClassMethods
      def queue_consumers
        @queue_consumers ||= {}
      end

      # Register a handler for a queue.
      #
      #   consume_queue 'jobs' do |batch|
      #     batch.messages.each { |m| ...; m.ack }
      #   end
      def consume_queue(queue_name, &block)
        raise ArgumentError, 'consume_queue requires a block' unless block
        qname = queue_name.to_s
        raise ArgumentError, 'queue_name must be non-empty' if qname.empty?

        method_name = "__queue_handler_#{qname.gsub(/[^A-Za-z0-9_]/, '_')}".to_sym
        ::Cloudflare::QueueContext.send(:define_method, method_name, &block)
        unbound = ::Cloudflare::QueueContext.instance_method(method_name)
        ::Cloudflare::QueueContext.send(:remove_method, method_name)

        queue_consumers[qname] = unbound
        ::Cloudflare::QueueConsumer.register(qname, unbound)
        nil
      end
    end

    def self.registered(app)
      app.extend(ClassMethods)
    end
  end

  Base.register Queue if defined?(::Sinatra::Base)
end
