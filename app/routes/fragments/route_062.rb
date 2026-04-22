# await: true
# frozen_string_literal: true
# Route fragment 62 — demo /docs/sequel-d1
get '/docs/sequel-d1' do
  @title = 'sequel-d1 — homurabi Docs'
  @docs_page = 'sequel-d1'
  @docs_section = :reference
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['API Reference', '/docs/runtime'],
    ['sequel-d1', nil]
  ]
  @docs_toc = [
    %w[connect 接続],
    %w[migrate マイグレーション],
    %w[opal Opal ビルドパス],
    %w[matrix できること / できないこと]
  ]
  @docs_inner = erb :docs_sequel_d1
  erb :layout_docs
end
