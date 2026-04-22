# frozen_string_literal: true
# Route fragment 4 — api /api/echo
post '/api/echo' do
  content_type 'application/json'
  request.body.rewind
  body = request.body.read
  "{\"echo\": \"#{body}\"}"
end
