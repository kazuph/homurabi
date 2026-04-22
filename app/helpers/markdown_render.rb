# frozen_string_literal: true

module Homurabi
  module MarkdownRenderHelpers
    def markdown_html(text)
      HomurabiMarkdown.render(text)
    end
  end
end
