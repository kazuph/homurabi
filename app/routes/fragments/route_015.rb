# frozen_string_literal: true
# Route fragment 15 — demo /kv/:key
delete '/kv/:key' do
  content_type 'application/json'
  key = params['key']
  kv.delete(key)
  { 'key' => key, 'deleted' => true }.to_json
end
