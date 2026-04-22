# await: true
# frozen_string_literal: true
# Route fragment 59 — demo /docs/quick-start
get '/docs/quick-start' do
  @title = 'クイックスタート — homurabi Docs'
  @docs_page = 'quick-start'
  @docs_section = :getting_started
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['Getting Started', '/docs'],
    ['Quick Start', nil]
  ]
  @docs_toc = [
    %w[prereq 前提],
    %w[scaffold 新規プロジェクト],
    %w[run-local ローカルで動かす],
    %w[deploy デプロイ],
    %w[limits 現在の制限]
  ]
  @docs_inner = erb :docs_quick_start
  erb :layout_docs
end
