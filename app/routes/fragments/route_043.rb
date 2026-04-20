# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 43 — demo /demo/queue/status
  get '/demo/queue/status' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    if kv.nil?
      status 503
      next({ 'error' => 'KV not bound — cannot read consumer state' }.to_json)
    end
    limit = (params['limit'] || '10').to_i
    recent = []
    i = 0
    while i < limit
      raw = kv.get("queue:last-consumed:#{i}").__await__
      break if raw.nil? || raw.empty?
      begin
        recent << JSON.parse(raw)
      rescue JSON::ParserError
        recent << { 'raw' => raw }
      end
      i += 1
    end
    {
      'queue'   => 'homurabi-jobs',
      'count'   => recent.size,
      'recent'  => recent
    }.to_json
  end
