# await: true
# frozen_string_literal: true
# Route fragment 14 — demo /kv/:key
put '/kv/:key' do
  content_type 'application/json'
  key  = params['key']
  body = request.body.read
  kv.put(key, body)
  status 201
  { 'key' => key, 'value' => body, 'stored' => true }.to_json
end
