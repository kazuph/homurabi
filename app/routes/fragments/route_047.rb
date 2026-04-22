# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 47 — demo /demo/queue/force-dlq
post '/demo/queue/force-dlq' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled' }.to_json)
  end
  q = jobs_queue
  if q.nil?
    status 503
    next({ 'error' => 'Queue binding JOBS_QUEUE not bound' }.to_json)
  end
  payload = { 'fail' => true, 'reason' => 'force-dlq demo', 'ts' => Time.now.to_i }
  q.send(payload)
  status 202
  { 'enqueued' => true, 'payload' => payload, 'note' => 'main consumer will retry up to max_retries; then the runtime forwards the message to homurabi-jobs-dlq' }.to_json
end
