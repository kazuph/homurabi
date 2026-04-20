# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 10 — posts /posts
  get '/posts' do
    content_type 'application/json'
    seq_db = Sequel.connect(adapter: :d1, d1: db)
    rows = seq_db[:posts].order(Sequel.desc(:id)).limit(20).all
    { 'count' => rows.size, 'posts' => rows }.to_json
  end
