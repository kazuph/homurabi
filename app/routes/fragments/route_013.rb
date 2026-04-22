# await: true
# frozen_string_literal: true
# Route fragment 13 — demo /kv/:key
get '/kv/:key' do
  content_type 'application/json'
  key = params['key']
  value = kv.get(key)
  if value.nil?
    status 404
    { 'error' => 'not found', 'key' => key }.to_json
  else
    { 'key' => key, 'value' => value }.to_json
  end
end
