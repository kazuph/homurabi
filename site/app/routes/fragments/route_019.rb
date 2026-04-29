# frozen_string_literal: true
# Route fragment 19 — demo /r2/:key
delete '/r2/:key' do
  content_type 'application/json'
  key    = params['key']
  bucket.delete(key)
  { 'key' => key, 'deleted' => true }.to_json
end
