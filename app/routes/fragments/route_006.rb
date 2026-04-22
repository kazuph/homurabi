# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 6 — demo /d1/users/:id
get '/d1/users/:id' do
  content_type 'application/json'
  id = params['id'].to_i
  row = db.get_first_row('SELECT id, name FROM users WHERE id = ?', [id])
  if row.nil?
    status 404
    { 'error' => 'not found', 'id' => id }.to_json
  else
    row.to_json
  end
end
