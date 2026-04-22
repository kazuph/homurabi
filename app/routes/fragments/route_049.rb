# await: true
# frozen_string_literal: true
# Route fragment 49 — demo /demo/faraday
get '/demo/faraday' do
  content_type 'application/json'
  unless foundations_demos_enabled?
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  client = Faraday.new(url: 'https://api.ipify.org') do |c|
    c.request :json
    c.response :json
    c.headers['user-agent'] = 'homurabi-phase11a/1.0'
  end
  res = client.get('/', { 'format' => 'json' })
  {
    'demo'        => 'Faraday.new(url:) { request :json; response :json }',
    'status'      => res.status,
    'success'     => res.success?,
    'reason'      => res.reason_phrase,
    'body'        => res.body,  # parsed Hash thanks to :json middleware
    'headers_ct'  => res.headers['content-type']
  }.to_json
end
