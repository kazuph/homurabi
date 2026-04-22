# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
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
