# frozen_string_literal: true
# Route fragment 41 — demo /demo/cache/heavy
get '/demo/cache/heavy' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled (set HOMURA_ENABLE_BINDING_DEMOS=1)' }.to_json)
  end
  # Cache by request URL so different query strings produce different
  # cache entries (cache-busting with ?v=N works).
  cache_key = request.url
  ttl = (params['ttl'] || '60').to_i
  started = Time.now.to_f
  compute_body = proc do
    # Expensive work: derive a PBKDF2 key + hash many times so the
    # first-request latency is non-trivial. The exact ~1000 iterations
    # is a compromise between "clearly slower than a cache hit" and
    # "finishes inside wrangler dev's request budget on an M1".
    salt = SecureRandom.random_bytes(16)
    derived = OpenSSL::KDF.pbkdf2_hmac('homura-phase11b',
      salt: salt, iterations: 50_000, length: 32, hash: 'SHA256')
    {
      'computed'    => 'expensive PBKDF2 derivation',
      'iterations'  => 50_000,
      'derived_hex' => derived.unpack1('H*'),
      'salt_hex'    => salt.unpack1('H*'),
      'computed_at' => Time.now.to_i
    }.to_json
  end
  body = cache_get(cache_key, ttl: ttl, &compute_body)
  elapsed_ms = ((Time.now.to_f - started) * 1000).round
  # The helper set response.headers['x-homura-cache'] to HIT / MISS.
  cache_state = response['X-Homura-Cache'] || 'UNKNOWN'
  # Re-serialise with extra diagnostic fields so the route caller can
  # see which path ran without cracking open headers from a browser.
  orig = begin
    JSON.parse(body)
  rescue JSON::ParserError
    { 'raw' => body }
  end
  orig.merge(
    'cache'      => cache_state,
    'elapsed_ms' => elapsed_ms,
    'cache_key'  => cache_key,
    'ttl'        => ttl
  ).to_json
end
