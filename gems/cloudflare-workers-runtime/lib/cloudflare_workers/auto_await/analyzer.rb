# frozen_string_literal: true

require 'parser/current'
require 'parser/source/tree_rewriter'

module CloudflareWorkers
  module AutoAwait
    class Analyzer
      def initialize(registry, debug: false)
        @registry = registry
        @debug = debug
        @await_nodes = []
        @env = {}
        @method_returns = {}
      end

      def process(source, filename = '(auto-await)')
        buffer = Parser::Source::Buffer.new(filename)
        buffer.source = source
        parser = Parser::CurrentRuby.new
        ast = parser.parse(buffer)
        @await_nodes = []
        @env = {}
        process_node(ast)
        [buffer, @await_nodes]
      end

      private

      def process_node(node)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def
          process_def(node)
          return
        end

        # Bottom-up traversal: process children first so helper-factory
        # sends (e.g. bare +db+) populate @env before their parent
        # send (e.g. +db.execute(...)+) is checked by should_await?.
        node.children.each { |child| process_node(child) if child.is_a?(Parser::AST::Node) }
        case node.type
        when :lvasgn
          process_lvasgn(node)
        when :ivasgn
          process_ivasgn(node)
        when :send
          process_send(node)
        end
      end

      def process_lvasgn(node)
        name, value = *node
        cls = infer_class(value)
        if cls
          @env[name] = cls
        else
          @env.delete(name)
        end
      end

      def process_ivasgn(node)
        _name, value = *node
        cls = infer_class(value)
        # instance variable tracking is best-effort; skip storing for now
      end

      def process_def(node)
        method_name = node.children[0]
        saved_env = @env
        @env = @registry.helper_factories.dup

        node.children[1..-1].each { |child| process_node(child) if child.is_a?(Parser::AST::Node) }

        body = node.children[2]
        return_cls = infer_class(body)
        @method_returns[method_name] = return_cls if return_cls

        @env = saved_env
      end

      def process_send(node)
        receiver, method_name = *node
        if receiver.nil? && (factory_cls = @registry.helper_factories[method_name])
          @env[method_name] = factory_cls
        end
        if should_await?(node)
          @await_nodes << node
          debug "await target: #{node.loc.expression.source}"
        end
      end

      def should_await?(node)
        return false unless node.type == :send
        receiver, method_name = *node
        if receiver
          recv_cls = infer_class(receiver)
          return true if recv_cls && @registry.async?(recv_cls, method_name)
        end
        # Receiver-less calls (implicit self) — check helpers.
        helpers = @registry.async_helpers[method_name]
        return true if helpers && !helpers.empty?
        false
      end

      def infer_class(node)
        return nil unless node.is_a?(Parser::AST::Node)
        case node.type
        when :send
          receiver, method_name = *node
          if receiver.nil?
            return @env[method_name] if @env.key?(method_name)
            return @method_returns[method_name] if @method_returns.key?(method_name)
          end
          infer_send_class(node)
        when :index
          infer_index_class(node)
        when :lvar
          @env[node.children[0]]
        when :ivar
          nil
        when :const
          const_path(node)
        else
          nil
        end
      end

      def infer_send_class(node)
        receiver, method_name = *node
        if method_name == :new && receiver&.type == :const
          return const_path(receiver)
        end
        if receiver
          if method_name == :[]
            key_node = node.children[2]
            if key_node&.type == :str
              key = key_node.children[0]
              mapped = @registry.async_accessors[[env_name(receiver), key.to_sym]]
              return mapped if mapped
            end
          end
          accessor_cls = infer_env_accessor(receiver, method_name)
          return accessor_cls if accessor_cls
          recv_cls = infer_class(receiver)
          if recv_cls
            factory = @registry.factory?(recv_cls, method_name)
            return recv_cls if factory
            ret = @registry.taint_return_class(recv_cls, method_name)
            return ret if ret
          end
        else
          return @method_returns[method_name] if @method_returns.key?(method_name)
        end
        nil
      end

      def infer_index_class(node)
        recv_cls = infer_class(node.children[0])
        return nil unless recv_cls
        @registry.taint_return_class(recv_cls, :[]) || recv_cls
      end

      def infer_env_accessor(receiver_node, method_name)
        if env_node?(receiver_node)
          return nil unless method_name.to_s =~ /^[A-Z]/
          lvar = env_name(receiver_node)
          mapped = @registry.async_accessors[[lvar, method_name.to_sym]]
          return mapped if mapped
        end
        if receiver_node.type == :send
          recv, meth = *receiver_node
          if meth == :[] && env_node?(recv)
            key_node = receiver_node.children[2]
            if key_node&.type == :str
              key = key_node.children[0]
              mapped = @registry.async_accessors[[env_name(recv), key.to_sym]]
              return mapped if mapped
            end
            lvar = env_name(recv)
            mapped = @registry.async_accessors[[lvar, method_name.to_sym]]
            return mapped if mapped
          elsif env_node?(recv)
            return nil unless method_name.to_s =~ /^[A-Z]/
            lvar = env_name(recv)
            mapped = @registry.async_accessors[[lvar, method_name.to_sym]]
            return mapped if mapped
          end
          parent_cls = infer_env_accessor(recv, meth) if recv&.type == :send
          return parent_cls if parent_cls
        elsif receiver_node.type == :lvar
          lvar = receiver_node.children[0]
          mapped = @registry.async_accessors[[lvar, method_name.to_sym]]
          return mapped if mapped
        end
        nil
      end

      def env_node?(node)
        return false unless node&.type == :send
        node.children[0].nil? && node.children[1] == :env
      end

      def env_name(node)
        :env
      end

      def const_path(node)
        parts = []
        n = node
        while n&.type == :const
          parts.unshift(n.children[1])
          n = n.children[0]
        end
        parts.join('::')
      end

      def debug(msg)
        puts "[auto-await] #{msg}" if @debug
      end
    end
  end
end
