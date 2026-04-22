# await: true
# frozen_string_literal: true
# Route fragment 5 — demo /d1/users
get '/d1/users' do
  content_type 'application/json'
  db.execute('SELECT id, name FROM users ORDER BY id').to_json
end
