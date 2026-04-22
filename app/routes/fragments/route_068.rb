# frozen_string_literal: true
# Route fragment 68 — demo /docs/email
get '/docs/email' do
  @title = 'Cloudflare Email Service — homurabi Docs'
  @docs_page = 'email'
  @docs_section = :reference
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['API Reference', '/docs/runtime'],
    ['Email Service', nil]
  ]
  @docs_toc = [
    %w[overview 概要],
    %w[setup domain onboarding],
    %w[wrapper Cloudflare::Email],
    %w[matrix できること / できないこと],
    %w[debug /debug/mail],
    %w[links 公式リンク]
  ]
  @docs_inner = erb :docs_email
  erb :layout_docs
end
