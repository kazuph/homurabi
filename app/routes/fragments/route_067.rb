# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 67 — demo /docs/email
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
