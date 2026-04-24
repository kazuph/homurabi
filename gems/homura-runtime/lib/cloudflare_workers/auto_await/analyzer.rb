# frozen_string_literal: true

require 'parser/current'
require 'parser/source/tree_rewriter'
require 'set'

module CloudflareWorkers
  module AutoAwait
    class Analyzer
      def initialize(registry, debug: false)
        @registry = registry
        @debug = debug
        @await_nodes = []
        @env = {}
        @method_returns = {}
        @async_local_methods = Set.new
      end

      def process(source, filename = '(auto-await)')
        buffer = Parser::Source::Buffer.new(filename)
        buffer.source = source
        parser = Parser::CurrentRuby.new
        ast = parser.parse(buffer)
        @method_returns = {}
        @async_local_methods = Set.new

        analyze_pass(ast)
        analyze_pass(ast)
        [buffer, @await_nodes]
      end

      private

      def analyze_pass(ast)
        @await_nodes = []
        @env = {}
        process_node(ast)
      end

      def process_node(node)
        return unless node.is_a?(Parser::AST::Node)

        if node.type == :def
          process_def(node)
          return
        end
        if node.type == :block
          process_block(node)
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
        before_awaits = @await_nodes.length
        @env = @registry.helper_factories.dup

        node.children[1..-1].each { |child| process_node(child) if child.is_a?(Parser::AST::Node) }

        body = node.children[2]
        return_cls = infer_class(body)
        @method_returns[method_name] = return_cls if return_cls
        body_source = node.loc.expression&.source.to_s
        if @await_nodes.length > before_awaits || body_source.include?('.__await__')
          @async_local_methods << method_name
        end

        @env = saved_env
      end

      def process_block(node)
        call_node, args_node, body = *node
        saved_env = @env
        @env = @env.dup

        block_param_bindings(call_node, args_node).each do |name, cls|
          @env[name] = cls
        end

        process_node(call_node) if call_node.is_a?(Parser::AST::Node)
        process_node(body) if body.is_a?(Parser::AST::Node)
      ensure
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
        return true if @async_local_methods.include?(method_name)
        false
      end

      def infer_class(node)
        return nil unless node.is_a?(Parser::AST::Node)
        case node.type
        when :send
          receiver, method_name = *node
          if receiver.nil?
            return @method_returns[method_name] if @method_returns.key?(method_name)
            return @env[method_name] if @env.key?(method_name)
          end
          infer_send_class(node)
        when :index
          infer_index_class(node)
        when :begin
          infer_class(node.children.last)
        when :lvar
          @env[node.children[0]]
        when :ivar
          nil
        when :or_asgn
          infer_class(node.children.last)
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

      def block_param_bindings(call_node, args_node)
        return {} unless durable_object_define_call?(call_node)
        return {} unless args_node&.type == :args

        arg_names = args_node.children.filter_map do |arg|
          next unless arg&.type == :arg
          arg.children[0]
        end
        return {} if arg_names.empty?

        bindings = { arg_names[0] => 'Cloudflare::DurableObjectState' }
        bindings[arg_names[1]] = 'Cloudflare::DurableObjectRequest' if arg_names.length > 1
        bindings
      end

      def durable_object_define_call?(call_node)
        return false unless call_node&.type == :send

        receiver, method_name = *call_node
        method_name == :define && const_path(receiver) == 'Cloudflare::DurableObject'
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
