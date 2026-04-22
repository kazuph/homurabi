# frozen_string_literal: true
# Route fragment 60 — demo /docs/migration
get '/docs/migration' do
  @title = '移行ガイド — homura Docs'
  @docs_page = 'migration'
  @docs_section = :guides
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['Migration Guide', nil]
  ]
  @docs_toc = [
    %w[scope 対象と非対象],
    %w[steps 6 ステップ],
    %w[gotchas よくあるハマり],
    %w[blockers 移行が難しい例]
  ]
  @docs_inner = erb :docs_migration
  erb :layout_docs
end
