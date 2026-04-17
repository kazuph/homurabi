# frozen_string_literal: true
#
# homurabi patch: simplified from ruby-jwt v2.9.3 deprecations.rb.
# Thread-local storage is replaced with a module-level @store because
# Opal has no Thread.current and JWT.decode always runs on one worker
# isolate at a time.

module JWT
  module Deprecations
    @warned = []
    @store  = nil

    class << self
      def context
        @store = []
        result = yield
        emit_warnings
        result
      ensure
        @store = nil
      end

      def warning(message, only_if_valid: false)
        method_name = only_if_valid ? :store : :warn
        case JWT.configuration.deprecation_warnings
        when :once
          return if record_warned(message)
        when :warn
          # noop
        else
          return
        end

        send(method_name, "[DEPRECATION WARNING] #{message}")
      end

      def store(message)
        (@store ||= []) << message
      end

      def emit_warnings
        return if @store.nil?

        @store.each { |msg| warn(msg) }
      end

      private

      def record_warned(message)
        return true if @warned.include?(message)

        @warned << message
        false
      end
    end
  end
end
