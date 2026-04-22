# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 60 — demo /docs/migration
get '/docs/migration' do
  @title = '移行ガイド — homurabi Docs'
  @docs_page = 'migration'
  @docs_section = :guides
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['Migration Guide', nil]
  ]
  @docs_toc = [
    %w[scope 対象と非対象],
    %w[steps 6 ステップ],
    %w[gotchas よくあるハマり],
    %w[blockers 移行が難しい例]
  ]
  @docs_inner = erb :docs_migration
  erb :layout_docs
end
