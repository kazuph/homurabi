# await: true
# frozen_string_literal: true
# Route fragment 6 — demo /d1/users/:id
get '/d1/users/:id' do
  content_type 'application/json'
  id = params['id'].to_i
  row = db.get_first_row('SELECT id, name FROM users WHERE id = ?', [id])
  if row.nil?
    status 404
    { 'error' => 'not found', 'id' => id }.to_json
  else
    row.to_json
  end
end
