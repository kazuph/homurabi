# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 62 — demo /docs/sinatra
  get '/docs/sinatra' do
    @title = 'sinatra-cloudflare-workers — homurabi Docs'
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
