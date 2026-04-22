# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 20 — demo /demo/http
get '/demo/http' do
  content_type 'application/json'
  res = Net::HTTP.get_response(URI('https://api.ipify.org/?format=json'))
  {
    'demo'    => 'Net::HTTP through Cloudflare fetch',
    'status'  => res.code,
    'message' => res.message,
    'content_type' => res['content-type'],
    'body'    => JSON.parse(res.body)
  }.to_json
end
