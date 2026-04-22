# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 42 — api /api/enqueue
post '/api/enqueue' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
  end
  q = jobs_queue
  if q.nil?
    status 503
    next({ 'error' => 'Queue binding JOBS_QUEUE not bound (wrangler.toml missing [[queues.producers]])' }.to_json)
  end
  begin
    body = JSON.parse(request.body.read)
  rescue JSON::ParserError, StandardError
    body = { 'note' => 'default payload (empty or invalid JSON body)', 'ts' => Time.now.to_i }
  end
  q.send(body)
  status 202
  { 'enqueued' => true, 'queue' => 'homurabi-jobs', 'payload' => body }.to_json
end
