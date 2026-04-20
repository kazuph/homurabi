# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 54 — demo /phase11a/download/*
  get '/phase11a/download/*' do
    unless foundations_demos_enabled?
      content_type 'application/json'
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    if bucket.nil?
      content_type 'application/json'
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end
    key = params['splat'].is_a?(Array) ? params['splat'].join('/') : params['splat'].to_s
    obj = bucket.get_binary(key)
    if obj.nil?
      content_type 'application/json'
      status 404
      next({ 'error' => 'not found', 'key' => key }.to_json)
    else
      obj  # BinaryBody — build_js_response streams raw bytes to client
    end
  end
