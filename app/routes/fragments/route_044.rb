# await: true
# frozen_string_literal: true
# Route fragment 44 — demo /demo/cache/named
get '/demo/cache/named' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled' }.to_json)
  end
  namespace = (params['namespace'] || 'frag-default').to_s
  # Copilot review PR #9 (third pass): return a stable 400 JSON
  # response on client input validation failures instead of
  # raising — the app has no Sinatra error handler for
  # ArgumentError, which would otherwise surface as 500.
  unless namespace =~ /\A[A-Za-z0-9_-]{1,32}\z/
    status 400
    next({ 'error' => 'namespace must match /\\A[A-Za-z0-9_-]{1,32}\\z/',
           'got'   => namespace }.to_json)
  end
  key = (params['key'] || 'demo').to_s
  unless key =~ /\A[A-Za-z0-9._\-\/]{1,128}\z/
    status 400
    next({ 'error' => 'key must match /\\A[A-Za-z0-9._\\-\\/]{1,128}\\z/',
           'got'   => key }.to_json)
  end
  cache_key = "https://homurabi-named-cache.internal/#{namespace}/#{key}"
  started = Time.now.to_f
  # Open the named partition fresh per request — the JS handle is
  # cached per-isolate internally but the Ruby wrapper is cheap.
  named = ::Cloudflare::Cache.open(namespace)
  cached = named.match(cache_key)
  if cached
    state = 'HIT'
    # Tiny pass-through of the cached body.
    payload = JSON.parse(cached.body) rescue { 'raw' => cached.body }
    payload.merge(
      'cache' => state,
      'namespace' => namespace,
      'key' => key,
      'elapsed_ms' => ((Time.now.to_f - started) * 1000).round
    ).to_json
  else
    state = 'MISS'
    # Compute something uniquely attributable to this namespace/key
    # so we can assert that two namespaces with the same key don't
    # collide.
    payload = {
      'namespace' => namespace,
      'key'       => key,
      'nonce'     => SecureRandom.hex(8),
      'computed_at' => Time.now.to_i
    }
    named.put(cache_key, payload.to_json, status: 200, headers: {
      'content-type'  => 'application/json',
      'cache-control' => 'public, max-age=60',
      'date'          => Time.now.httpdate
    })
    payload.merge(
      'cache' => state,
      'elapsed_ms' => ((Time.now.to_f - started) * 1000).round
    ).to_json
  end
end
