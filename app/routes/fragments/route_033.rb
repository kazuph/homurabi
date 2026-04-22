# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 33 — api /api/chat/health
get '/api/chat/health' do
  content_type 'application/json'
  {
    'ok'             => true,
    'demos_enabled'  => ai_demos_enabled?,
    'ai_bound'       => ai_binding?,
    'kv_bound'       => !kv.nil?,
    'primary_model'  => CHAT_MODELS[:primary],
    'fallback_model' => CHAT_MODELS[:fallback]
  }.to_json
end
