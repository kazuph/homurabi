# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 8 — demo /demo/sequel
get '/demo/sequel' do
  content_type 'application/json'
  seq_db = Sequel.connect(adapter: :d1, d1: db)
  rows = seq_db[:users].order(:id).limit(10).all
  { 'rows' => rows, 'adapter' => 'sequel-d1', 'dialect' => 'sqlite' }.to_json
end
