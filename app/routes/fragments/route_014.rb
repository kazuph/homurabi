# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 14 — demo /kv/:key
  put '/kv/:key' do
    content_type 'application/json'
    key  = params['key']
    body = request.body.read
    kv.put(key, body).__await__
    status 201
    { 'key' => key, 'value' => body, 'stored' => true }.to_json
  end
