# await: true
# frozen_string_literal: true
# Route fragment 36 — api /api/chat/messages
delete '/api/chat/messages' do
  content_type 'application/json'
  gate = ai_demos_block_or_nil
  next gate if gate
  auth = chat_verify_token!
  if auth['ok'] != true
    # See the long comment in POST /api/chat/messages for why we
    # return [status, body] instead of using `status N; next body`
    # — Sinatra snapshots response.status before the await resolves,
    # so any later mutation is lost.
    next [auth['status'].to_i, auth['body']]
  end
  session_id = normalize_session_id(params['session'])
  clear_chat_history(session_id)
  { 'ok' => true, 'session' => session_id, 'cleared' => true }.to_json
end
