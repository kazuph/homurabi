# frozen_string_literal: true

module Homura
  module MarkdownRenderHelpers
    def markdown_html(text)
      HomuraMarkdown.render(text)
    end
  end
end
