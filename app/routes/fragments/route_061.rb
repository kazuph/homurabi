# frozen_string_literal: true
# Route fragment 61 — demo /docs/sinatra
get '/docs/sinatra' do
  @title = 'sinatra-cloudflare-workers — homura Docs'
  @docs_page = 'sinatra'
  @docs_section = :reference
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['API Reference', '/docs/runtime'],
    ['sinatra-cloudflare-workers', nil]
  ]
  @docs_toc = [
    %w[overview 概要],
    %w[register 登録と require],
    %w[erb ERB プリコンパイル],
    %w[jwt JWT],
    %w[scheduled Cron],
    %w[queue Queues],
    %w[matrix できること / できないこと]
  ]
  @docs_inner = erb :docs_sinatra
  erb :layout_docs
end
