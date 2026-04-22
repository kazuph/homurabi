# frozen_string_literal: true

module CloudflareWorkers
  module AutoAwait
    class Transformer
      def self.transform(source, await_nodes, buffer)
        rewriter = Parser::Source::TreeRewriter.new(buffer)
        await_nodes.each do |node|
          range = node.loc.expression
          next unless range
          rewriter.replace(range, "#{range.source}.__await__")
        end
        rewriter.process
      end
    end
  end
end
