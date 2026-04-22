# await: true
# frozen_string_literal: true
# Route fragment 35 — api /api/chat/messages
get '/api/chat/messages' do
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
  history = load_chat_history(session_id)
  # Include a pre-rendered HTML for each message so the client can
  # show Markdown-formatted history without re-running a JS parser.
  history_enriched = history.map do |m|
    role = m['role'].to_s
    content = m['content'].to_s
    item = { 'role' => role, 'content' => content }
    # Only assistant replies are converted — user messages are
    # authored text and stay as-is to preserve the exact payload.
    item['content_html'] = markdown_html(content) if role == 'assistant'
    item
  end
  {
    'session' => session_id,
    'history' => history_enriched
  }.to_json
end
