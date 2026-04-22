# frozen_string_literal: true
# Route fragment 63 — demo /docs/runtime
get '/docs/runtime' do
  @title = 'cloudflare-workers-runtime — homurabi Docs'
  @docs_page = 'runtime'
  @docs_section = :reference
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['API Reference', '/docs/runtime'],
    ['cloudflare-workers-runtime', nil]
  ]
  @docs_toc = [
    %w[role 役割],
    %w[build ビルド CLI],
    %w[entrypoint worker.entrypoint.mjs],
    %w[matrix できること / できないこと]
  ]
  @docs_inner = erb :docs_runtime
  erb :layout_docs
end
