# await: true
# frozen_string_literal: true
# Route fragment 17 — demo /r2/:key
get '/r2/:key' do
  content_type 'application/json'
  key    = params['key']
  obj    = bucket.get(key)
  if obj.nil?
    status 404
    { 'error' => 'not found', 'key' => key }.to_json
  else
    {
      'key'  => obj['key'],
      'body' => obj['body'],
      'etag' => obj['etag'],
      'size' => obj['size']
    }.to_json
  end
end
