# frozen_string_literal: true
# Route fragment 20 — demo /demo/http
get '/demo/http' do
  content_type 'application/json'
  res = Net::HTTP.get_response(URI('https://api.ipify.org/?format=json'))
  {
    'demo'    => 'Net::HTTP through Cloudflare fetch',
    'status'  => res.code,
    'message' => res.message,
    'content_type' => res['content-type'],
    'body'    => JSON.parse(res.body)
  }.to_json
end
