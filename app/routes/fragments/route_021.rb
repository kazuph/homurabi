# await: true
# frozen_string_literal: true
# Route fragment 21 — demo /demo/http/raw
get '/demo/http/raw' do
  content_type 'application/json'
  res = Cloudflare::HTTP.fetch('https://api.ipify.org/?format=json')
  {
    'demo'    => 'Cloudflare::HTTP.fetch (raw)',
    'status'  => res.status,
    'ok'      => res.ok?,
    'headers' => { 'content-type' => res['content-type'] },
    'json'    => res.json
  }.to_json
end
