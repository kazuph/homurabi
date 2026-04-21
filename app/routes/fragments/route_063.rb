# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 63 — demo /docs/architecture
  get '/docs/architecture' do
    @title = 'アーキテクチャ — homurabi Docs'
    @docs_page = 'architecture'
    @docs_section = :architecture
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['Architecture', nil]
    ]
    @docs_toc = [
      %w[self-host セルフホスト],
      %w[gems 3 gem の関係],
      %w[pipeline ビルドパイプライン],
      %w[history Phase 15 の整理],
      %w[diagram 依存関係 (Mermaid)]
    ]
    @docs_inner = erb :docs_architecture
    erb :layout_docs
  end
