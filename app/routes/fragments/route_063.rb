# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 63 — demo /docs/sequel-d1
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
