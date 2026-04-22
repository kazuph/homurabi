# await: true
# frozen_string_literal: true
# Route fragment 64 — demo /docs/auto-await
get '/docs/auto-await' do
  @title = 'Auto-Await — homurabi Docs'
  @docs_page = 'auto-await'
  @docs_section = :guides
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['Guides', '/docs'],
    ['Auto-Await', nil]
  ]
  @docs_toc = [
    %w[concept 概念],
    %w[before-after Before / After],
    %w[registry AsyncRegistry],
    %w[diagnostic 診断モード],
    %w[limits 制限とフォールバック]
  ]
  @docs_inner = erb :docs_auto_await
  erb :layout_docs
end
