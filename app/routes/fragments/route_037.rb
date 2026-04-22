# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 37 — test /test/ai/debug
get '/test/ai/debug' do
  content_type 'application/json'
  unless ai_demos_enabled? && ai_binding?
    status 404
    next({ 'error' => 'disabled' }.to_json)
  end
  model = params['model'] || CHAT_MODELS[:primary]
  out = Cloudflare::AI.run(
    model,
    { messages: [
      { role: 'system', content: 'reply with a short Japanese greeting' },
      { role: 'user',   content: 'こんにちは' }
    ], max_tokens: 64 },
    binding: ai_binding
  )
  {
    'model'    => model,
    'class'    => out.class.to_s,
    'is_hash'  => out.is_a?(Hash),
    'keys'     => out.is_a?(Hash) ? out.keys : nil,
    'extracted'=> App.extract_ai_text(out),
    'raw'      => out
  }.to_json
end
