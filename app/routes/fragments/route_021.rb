# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 21 — demo /demo/http/raw
get '/demo/http/raw' do
  content_type 'application/json'
  res = Cloudflare::HTTP.fetch('https://api.ipify.org/?format=json')
  {
    'demo'    => 'Cloudflare::HTTP.fetch (raw)',
    'status'  => res.status,
    'ok'      => res.ok?,
    'headers' => { 'content-type' => res['content-type'] },
    'json'    => res.json
  }.to_json
end
