# await: true
# frozen_string_literal: true
# Route fragment 7 — demo /d1/users
post '/d1/users' do
  content_type 'application/json'
  begin
    payload = JSON.parse(request.body.read)
  rescue JSON::ParserError, StandardError => e
    status 400
    return { 'error' => 'invalid JSON body', 'detail' => e.message }.to_json
  end
  name = payload['name'].to_s
  if name.empty?
    status 400
    { 'error' => 'name required' }.to_json
  else
    row = db.get_first_row('INSERT INTO users (name) VALUES (?) RETURNING id, name', [name])
    status 201
    row.to_json
  end
end
