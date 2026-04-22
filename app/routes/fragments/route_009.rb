# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 9 — demo /demo/sequel/sql
get '/demo/sequel/sql' do
  content_type 'application/json'
  seq_db = Sequel.connect(adapter: :d1, d1: db)
  ds = seq_db[:users].where(active: true).order(:name).limit(10)
  { 'sql' => ds.sql.to_s, 'adapter' => 'sequel-d1' }.to_json
end
