# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 41 — demo /demo/cache/heavy
  get '/demo/cache/heavy' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    # Cache by request URL so different query strings produce different
    # cache entries (cache-busting with ?v=N works).
    cache_key = request.url
    ttl = (params['ttl'] || '60').to_i
    started = Time.now.to_f
    # cache_get uses `__await__` internally (cache.match / cache.put)
    # so the helper method is compiled as async by Opal — its return
    # value is a Promise we MUST `__await__` at the call site.
    body = cache_get(cache_key, ttl: ttl) do
      # Expensive work: derive a PBKDF2 key + hash many times so the
      # first-request latency is non-trivial. The exact ~1000 iterations
      # is a compromise between "clearly slower than a cache hit" and
      # "finishes inside wrangler dev's request budget on an M1".
      salt = SecureRandom.random_bytes(16)
      derived = OpenSSL::KDF.pbkdf2_hmac('homurabi-phase11b',
        salt: salt, iterations: 50_000, length: 32, hash: 'SHA256')
      {
        'computed'    => 'expensive PBKDF2 derivation',
        'iterations'  => 50_000,
        'derived_hex' => derived.unpack1('H*'),
        'salt_hex'    => salt.unpack1('H*'),
        'computed_at' => Time.now.to_i
      }.to_json
    end.__await__
    elapsed_ms = ((Time.now.to_f - started) * 1000).round
    # The helper set response.headers['x-homurabi-cache'] to HIT / MISS.
    cache_state = response['X-Homurabi-Cache'] || 'UNKNOWN'
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
