# frozen_string_literal: true
# Route fragment 16 — demo /images/:key
get '/images/:key' do
  key    = params['key']
  obj    = bucket.get_binary(key)
  if obj.nil?
    status 404
    'not found'
  else
    obj  # BinaryBody — build_js_response detects and streams directly
  end
end
