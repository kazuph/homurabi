# frozen_string_literal: true
# Route fragment 65 — demo /docs/architecture
get '/docs/architecture' do
  @title = 'アーキテクチャ — homurabi Docs'
  @docs_page = 'architecture'
  @docs_section = :architecture
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['Architecture', nil]
  ]
  @docs_toc = [
    %w[self-host セルフホスト],
    %w[gems 3 gem の関係],
    %w[pipeline ビルドパイプライン],
    %w[history Phase 15 の整理],
    %w[diagram 依存関係 (Mermaid)]
  ]
  @docs_inner = erb :docs_architecture
  erb :layout_docs
end
