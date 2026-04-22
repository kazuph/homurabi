# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 11 — posts /posts
post '/posts' do
  content_type 'application/json'
  begin
    payload = JSON.parse(request.body.read)
  rescue JSON::ParserError, StandardError => e
    status 400
    next({ 'error' => "invalid JSON: #{e.message}" }.to_json)
  end
  title = payload['title'].to_s.strip
  body_text = payload['body'].to_s.strip
  if title.empty?
    status 400
    next({ 'error' => 'title is required' }.to_json)
  end
  # Use Cloudflare::D1Database directly for the insert + readback.
  # D1's execute() accepts `?` placeholders and binds as an Array,
  # matching sqlite3-ruby's idiom (same shape `/d1/users POST`
  # route already relies on).
  row = db.get_first_row(
    'INSERT INTO posts (title, body) VALUES (?, ?) RETURNING id, title, body, created_at',
    [title, body_text]
  )
  status 201
  { 'ok' => true, 'post' => row }.to_json
end
