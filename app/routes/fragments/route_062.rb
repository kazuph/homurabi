# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 62 — demo /docs/runtime
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
