# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 52 — demo /phase11a/cleanup
  post '/phase11a/cleanup' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    if bucket.nil?
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end
    rows = bucket.list(prefix: 'phase11a/uploads/', limit: 1000)
    deleted_keys = []
    rows.each do |row|
      ct = row['content_type'].to_s
      next if ct.start_with?('image/')
      k = row['key'].to_s
      # Double-check we're still in our prefix before deleting.
      next unless k.start_with?('phase11a/uploads/')
      bucket.delete(k).__await__
      deleted_keys << k
    end
    { 'deleted_count' => deleted_keys.length, 'deleted' => deleted_keys }.to_json
  end
