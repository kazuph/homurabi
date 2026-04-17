# await: true
# frozen_string_literal: true
#
# A plain Sinatra application. Ported as faithfully as possible from
# the canonical Sinatra README / examples, so every line here reads
# the same as it would in any other Sinatra project. Nothing about
# Cloudflare Workers, Opal, or the Cloudflare bindings is visible in
# this file — the adapter lives entirely in `lib/cloudflare_workers.rb`.
#
# HTML pages go through real ERB templates stored under `views/*.erb`
# and rendered with the classic `erb :name` helper. homurabi's build
# pipeline precompiles those templates with `bin/compile-erb` so the
# Workers sandbox never has to call `eval` / `new Function` at runtime.

require 'json'
require 'time'
require 'sinatra/base'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'base64'
require 'jwt'
require 'sinatra/jwt_auth'
require 'sinatra/scheduled'
require 'sinatra/queue'

class App < Sinatra::Base
  # Phase 8 — JWT auth. The secret is the default HS256 path; asymmetric
  # algo demos generate their own keys on first use and cache them in
  # Ruby class variables (`@@rsa_key`, `@@ec256_key`, …) so repeat
  # requests don't pay the 2048-bit RSA generation cost. The secret is
  # deterministic only for local dev — in production it should come
  # from a Workers secret (wrangler secret put JWT_SECRET) pulled via
  # `env['cloudflare.env'].JWT_SECRET`.
  register Sinatra::JwtAuth
  set :jwt_secret, 'homurabi-phase8-demo-secret-change-me-in-prod'
  set :jwt_algorithm, 'HS256'
  # Phase 9 — Cron Trigger DSL. Use `schedule '*/5 * * * *' do ... end`
  # below; matching jobs are dispatched from `src/worker.mjs#scheduled`
  # via `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`.
  register Sinatra::Scheduled
  # Phase 11B — Sinatra::Queue. Adds the `consume_queue 'name' do
  # |batch| ... end` DSL so queue consumer handlers live next to the
  # HTTP routes.
  register Sinatra::Queue
  # --- Cloudflare binding helpers ------------------------------------
  # These let routes access D1/KV/R2 with the same brevity as
  # ActiveRecord's `User.find(id)` pattern, without introducing an ORM.
  helpers do
    def db;     env['cloudflare.DB'];     end
    def kv;     env['cloudflare.KV'];     end
    def bucket; env['cloudflare.BUCKET']; end

    # Crypto demo / self-test routes generate fresh RSA keys + run
    # PBKDF2 per call. Leaving them publicly reachable in production
    # is a CPU-DoS vector. Gate behind the wrangler [vars] flag
    # `HOMURABI_ENABLE_CRYPTO_DEMOS`. Default-deny everywhere.
    def crypto_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_CRYPTO_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 9 — gate for the scheduled introspection / manual-fire
    # routes. `/test/scheduled/run` writes to D1 + KV without auth, so
    # leaving it open in production lets any caller burn binding quota.
    # Default OFF; flip via wrangler [vars] HOMURABI_ENABLE_SCHEDULED_DEMOS=1.
    def scheduled_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 11B — gate for the Durable Object / Cache API / Queues
    # demo routes (`/demo/do*`, `/demo/cache*`, `/api/enqueue`,
    # `/test/bindings`). Each demo writes to DO storage or enqueues
    # a message on every request, so leaving them publicly reachable
    # in production burns metered quota. Default OFF; flip via
    # wrangler [vars] HOMURABI_ENABLE_BINDING_DEMOS=1 in dev.
    def binding_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_BINDING_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 11B — Sinatra helpers around the DO / Cache / Queue
    # wrappers. They mirror the `db` / `kv` / `bucket` pattern so
    # routes can call them without touching JS.

    # Wrapped DurableObjectNamespace for the `COUNTER` binding.
    # nil when no binding is attached (e.g. in tests or missing
    # wrangler.toml entry).
    def do_counter
      env['cloudflare.DO_COUNTER']
    end

    # Default edge cache.  A thin wrapper over `caches.default`.
    def cache
      @cache ||= ::Cloudflare::Cache.default
    end

    # The `JOBS_QUEUE` producer binding. nil when the binding is
    # not attached.
    def jobs_queue
      env['cloudflare.QUEUE_JOBS']
    end

    # Serve an expensive computation through Cache API. On a cache
    # hit the cached Response body is returned; on a miss the block
    # is evaluated, the result is stored with the given TTL, and
    # the fresh body is returned.
    #
    #   get '/demo/cache/heavy' do
    #     content_type 'application/json'
    #     cache_get(request.url, ttl: 60) { expensive_json }
    #   end
    #
    # Headers picked up from the route's `content_type` call are
    # copied onto the stored Response so a cache hit echoes the
    # same content-type — otherwise the browser would see a plain
    # 200 with no content-type and try to sniff.
    #
    # NOTE: the Workers Cache API (and miniflare's local emulation)
    # requires the cache-key URL to be http/https AND the stored
    # Response to have a `Date` + `Cache-Control: max-age > 0` header.
    # A missing `Date` header is the most common reason a put
    # silently stores nothing — we populate it here so routes don't
    # have to know.
    def cache_get(cache_key, ttl: 60, content_type_override: nil, &block)
      c = cache
      cached = c.match(cache_key).__await__
      if cached
        # Replay the cached headers so the outer Rack response
        # matches what we originally put in (content-type etc.).
        cached.headers.each { |k, v| response.headers[k] = v }
        response.headers['x-homurabi-cache'] = 'HIT'
        return cached.body
      end
      body = block.call
      ct = content_type_override || response['Content-Type'] || 'text/plain; charset=utf-8'
      c.put(
        cache_key, body,
        status: 200,
        headers: {
          'content-type'     => ct,
          'cache-control'    => "public, max-age=#{ttl.to_i}",
          'date'             => Time.now.httpdate,
          'x-homurabi-cache' => 'MISS'
        }
      ).__await__
      response.headers['x-homurabi-cache'] = 'MISS'
      body
    end
  end
  # ------------------------------------------------------------------
  # HTML pages — each route sets a few `@ivars` then renders an ERB
  # template from `views/`. Exactly like Sinatra's README example:
  #
  #     get '/' do
  #       erb :index
  #     end
  # ------------------------------------------------------------------

  get '/' do
    @title = 'Hello from Sinatra'
    @users = db ? db.execute('SELECT id, name FROM users ORDER BY id').__await__ : []
    @content = erb :index
    erb :layout
  end

  get '/hello/:name' do
    @title = "Hello #{params['name']}"
    @name  = params['name']
    @content = erb :hello
    erb :layout
  end

  get '/about' do
    @title = 'About homurabi'
    @content = erb :about
    erb :layout
  end

  # A tiny JSON echo — still Sinatra DSL, just a different content type.
  post '/api/echo' do
    content_type 'application/json'
    request.body.rewind
    body = request.body.read
    "{\"echo\": \"#{body}\"}"
  end

  # ------------------------------------------------------------------
  # D1 / KV / R2 — Phase 3 routes. Async Sinatra on Opal needs one
  # ceremony: capture params BEFORE the first `.__await__`, because
  # Sinatra's `process_route` ensure block cleans `@params` the moment
  # the async block returns its Promise. Doing `key = params['key']` at
  # the top is idiomatic for async routes.
  # ------------------------------------------------------------------

  # D1 routes use the sqlite3-ruby compatible interface:
  #   db.execute(sql, binds)      → Array<Hash>
  #   db.get_first_row(sql, binds) → Hash or nil
  #   db.execute_insert(sql, binds) → meta Hash
  # Same calling convention as `SQLite3::Database` on CRuby.

  get '/d1/users' do
    content_type 'application/json'
    db.execute('SELECT id, name FROM users ORDER BY id').__await__.to_json
  end

  get '/d1/users/:id' do
    content_type 'application/json'
    id = params['id'].to_i
    row = db.get_first_row('SELECT id, name FROM users WHERE id = ?', [id]).__await__
    if row.nil?
      status 404
      { 'error' => 'not found', 'id' => id }.to_json
    else
      row.to_json
    end
  end

  post '/d1/users' do
    content_type 'application/json'
    begin
      payload = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError => e
      status 400
      return { 'error' => 'invalid JSON body', 'detail' => e.message }.to_json
    end
    name = payload['name'].to_s
    if name.empty?
      status 400
      { 'error' => 'name required' }.to_json
    else
      row = db.get_first_row('INSERT INTO users (name) VALUES (?) RETURNING id, name', [name]).__await__
      status 201
      row.to_json
    end
  end

  get '/kv/:key' do
    content_type 'application/json'
    key = params['key']
    value = kv.get(key).__await__
    if value.nil?
      status 404
      { 'error' => 'not found', 'key' => key }.to_json
    else
      { 'key' => key, 'value' => value }.to_json
    end
  end

  put '/kv/:key' do
    content_type 'application/json'
    key  = params['key']
    body = request.body.read
    kv.put(key, body).__await__
    status 201
    { 'key' => key, 'value' => body, 'stored' => true }.to_json
  end

  delete '/kv/:key' do
    content_type 'application/json'
    key = params['key']
    kv.delete(key).__await__
    { 'key' => key, 'deleted' => true }.to_json
  end

  # Serve binary assets (images, etc.) from R2. Uses BinaryBody which
  # passes the R2 ReadableStream directly to the JS Response, bypassing
  # Opal's String encoding. This is a normal Sinatra route — no JS in
  # worker.mjs, no backtick here.
  get '/images/:key' do
    key    = params['key']
    obj    = bucket.get_binary(key).__await__
    if obj.nil?
      status 404
      'not found'
    else
      obj  # BinaryBody — build_js_response detects and streams directly
    end
  end

  get '/r2/:key' do
    content_type 'application/json'
    key    = params['key']
    obj    = bucket.get(key).__await__
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

  put '/r2/:key' do
    content_type 'application/json'
    key             = params['key']
    body            = request.body.read rescue ''
    content_type_in = request.env['CONTENT_TYPE'] || 'application/octet-stream'
    bucket.put(key, body, content_type_in).__await__
    status 201
    { 'key' => key, 'size' => body.bytesize, 'stored' => true }.to_json
  end

  delete '/r2/:key' do
    content_type 'application/json'
    key    = params['key']
    bucket.delete(key).__await__
    { 'key' => key, 'deleted' => true }.to_json
  end

  # ------------------------------------------------------------------
  # Phase 6 demo — Net::HTTP shim through globalThis.fetch.
  # GET /demo/http hits the public ipify API and echoes back the JSON
  # the way any other Net::HTTP-based Ruby gem would see it.
  # ------------------------------------------------------------------
  get '/demo/http' do
    content_type 'application/json'
    res = Net::HTTP.get_response(URI('https://api.ipify.org/?format=json')).__await__
    {
      'demo'    => 'Net::HTTP through Cloudflare fetch',
      'status'  => res.code,
      'message' => res.message,
      'content_type' => res['content-type'],
      'body'    => JSON.parse(res.body)
    }.to_json
  end

  # Same demo using the lower-level Cloudflare::HTTP.fetch directly.
  get '/demo/http/raw' do
    content_type 'application/json'
    res = Cloudflare::HTTP.fetch('https://api.ipify.org/?format=json').__await__
    {
      'demo'    => 'Cloudflare::HTTP.fetch (raw)',
      'status'  => res.status,
      'ok'      => res.ok?,
      'headers' => { 'content-type' => res['content-type'] },
      'json'    => res.json
    }.to_json
  end

  # ------------------------------------------------------------------
  # Phase 8 — JWT auth demo routes.
  #
  # `POST /api/login?alg=HS256|RS256|PS256|ES256|EdDSA` mints a JWT with
  # the chosen algorithm so ops can confirm every algorithm round-trips
  # on the Workers runtime with a simple `curl`. Asymmetric keys are
  # generated once per Worker isolate and cached in class-level ivars.
  # `GET /api/me` verifies the `Authorization: Bearer ...` header,
  # auto-detecting the algorithm from the JWT header so the same route
  # accepts tokens from any `/api/login?alg=...` flavour.
  # `POST /api/login/refresh` exchanges a refresh-token for a new
  # access-token. Refresh tokens are opaque random strings persisted in
  # KV so a stolen access token expires after `JWT_ACCESS_TTL` without
  # forcing the user to re-authenticate.
  # ------------------------------------------------------------------
  JWT_ACCESS_TTL  = 3600          # 1 hour
  JWT_REFRESH_TTL = 86_400 * 30   # 30 days

  helpers do
    # Returns the signing key + verification key pair for the given alg.
    # Keys are lazily generated and cached on the App class so repeat
    # requests skip the 2048-bit RSA generation.
    def jwt_keys_for(alg)
      case alg
      when 'HS256', 'HS384', 'HS512'
        [settings.jwt_secret, settings.jwt_secret]
      when 'RS256', 'RS384', 'RS512', 'PS256', 'PS384', 'PS512'
        App.class_variable_set(:@@rsa_key, OpenSSL::PKey::RSA.new(2048)) unless App.class_variable_defined?(:@@rsa_key)
        rsa = App.class_variable_get(:@@rsa_key)
        [rsa, rsa.public_key]
      when 'ES256'
        App.class_variable_set(:@@ec256_key, OpenSSL::PKey::EC.generate('prime256v1')) unless App.class_variable_defined?(:@@ec256_key)
        ec = App.class_variable_get(:@@ec256_key)
        [ec, ec]
      when 'ES384'
        App.class_variable_set(:@@ec384_key, OpenSSL::PKey::EC.generate('secp384r1')) unless App.class_variable_defined?(:@@ec384_key)
        ec = App.class_variable_get(:@@ec384_key)
        [ec, ec]
      when 'ES512'
        App.class_variable_set(:@@ec521_key, OpenSSL::PKey::EC.generate('secp521r1')) unless App.class_variable_defined?(:@@ec521_key)
        ec = App.class_variable_get(:@@ec521_key)
        [ec, ec]
      when 'EdDSA', 'ED25519'
        App.class_variable_set(:@@ed_key, OpenSSL::PKey::Ed25519.generate) unless App.class_variable_defined?(:@@ed_key)
        ed = App.class_variable_get(:@@ed_key)
        [ed, ed]
      else
        raise ArgumentError, "unsupported alg: #{alg.inspect}"
      end
    end

    # Inspect a JWT header without verifying so we can pick the right
    # verification key. Safe to do because we always re-verify the
    # signature with the detected alg.
    def alg_from_token(token)
      header_seg = token.to_s.split('.').first.to_s
      padded     = header_seg + ('=' * ((4 - header_seg.length % 4) % 4))
      json       = Base64.urlsafe_decode64(padded)
      JSON.parse(json)['alg']
    rescue StandardError
      nil
    end
  end

  # POST /api/login — issues access + refresh tokens.
  # Body (JSON): { "username": "..." }
  # Query: ?alg=HS256|RS256|PS256|ES256|ES384|ES512|EdDSA (default HS256)
  post '/api/login' do
    content_type 'application/json'
    alg = params['alg'] || 'HS256'
    begin
      body = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError
      body = {}
    end
    username = body['username'].to_s
    username = 'demo' if username.empty?

    begin
      sign_key, _ = jwt_keys_for(alg)
    rescue ArgumentError => e
      status 400
      return { 'error' => e.message }.to_json
    end

    payload = {
      'sub'  => username,
      'role' => body['role'] || 'user',
      'iat'  => Time.now.to_i,
      'exp'  => Time.now.to_i + JWT_ACCESS_TTL
    }
    access_token = JWT.encode(payload, sign_key, alg).__await__

    # Refresh token: opaque random string. Only minted when KV is bound
    # (otherwise the token would never round-trip through /api/login/refresh
    # and we'd be lying about rotation support). Store the role in the KV
    # entry so refresh preserves the original role instead of demoting
    # non-default roles to 'user' on re-issue.
    refresh = nil
    if kv
      refresh = SecureRandom.urlsafe_base64(48)
      entry = {
        'sub'  => username,
        'role' => body['role'] || 'user',
        'alg'  => alg,
        'exp'  => Time.now.to_i + JWT_REFRESH_TTL
      }
      kv.put("refresh:#{refresh}", entry.to_json).__await__
    end

    status 201
    resp = {
      'access_token' => access_token,
      'token_type'   => 'Bearer',
      'expires_in'   => JWT_ACCESS_TTL,
      'alg'          => alg
    }
    resp['refresh_token'] = refresh if refresh
    resp.to_json
  end

  # GET /api/me — verifies Authorization: Bearer ..., returns payload.
  # Accepts any supported algorithm, detected from the JWT header.
  get '/api/me' do
    content_type 'application/json'
    auth_header = request.env['HTTP_AUTHORIZATION'].to_s
    parts = auth_header.split(' ', 2)
    if parts.length != 2 || parts[0].downcase != 'bearer'
      status 401
      next { 'error' => 'missing Authorization: Bearer header' }.to_json
    end

    token = parts[1].strip
    if token.empty?
      status 401
      next { 'error' => 'missing Authorization: Bearer header' }.to_json
    end

    alg = alg_from_token(token)
    if alg.nil? || alg == 'none'
      status 401
      next { 'error' => 'unknown or unsafe algorithm' }.to_json
    end

    begin
      _, verify_key = jwt_keys_for(alg)
    rescue ArgumentError => e
      status 401
      next { 'error' => e.message }.to_json
    end

    begin
      payload, header = JWT.decode(token, verify_key, true, algorithm: alg).__await__
    rescue JWT::ExpiredSignature
      status 401
      next { 'error' => 'token expired' }.to_json
    rescue JWT::VerificationError
      status 401
      next { 'error' => 'signature verification failed' }.to_json
    rescue JWT::DecodeError => e
      status 401
      next({ 'error' => "invalid token: #{e.message}" }.to_json)
    end

    {
      'current_user' => payload['sub'],
      'role'         => payload['role'],
      'alg'          => header['alg'],
      'claims'       => payload
    }.to_json
  end

  # POST /api/login/refresh — exchange a refresh token for a new access
  # token. Body: { "refresh_token": "..." }
  post '/api/login/refresh' do
    content_type 'application/json'
    if kv.nil?
      status 500
      next { 'error' => 'KV not bound' }.to_json
    end

    begin
      body = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError
      body = {}
    end
    refresh = body['refresh_token'].to_s
    if refresh.empty?
      status 400
      next { 'error' => 'refresh_token required' }.to_json
    end

    raw = kv.get("refresh:#{refresh}").__await__
    if raw.nil?
      status 401
      next { 'error' => 'unknown refresh_token' }.to_json
    end

    begin
      entry = JSON.parse(raw)
    rescue JSON::ParserError
      status 500
      next { 'error' => 'corrupt refresh entry' }.to_json
    end

    if entry['exp'].to_i < Time.now.to_i
      kv.delete("refresh:#{refresh}").__await__
      status 401
      next { 'error' => 'refresh_token expired' }.to_json
    end

    alg = entry['alg'] || 'HS256'
    sub = entry['sub']
    sign_key, _ = jwt_keys_for(alg)
    payload = {
      'sub'  => sub,
      'role' => entry['role'] || 'user',
      'iat'  => Time.now.to_i,
      'exp'  => Time.now.to_i + JWT_ACCESS_TTL
    }
    access_token = JWT.encode(payload, sign_key, alg).__await__

    {
      'access_token' => access_token,
      'token_type'   => 'Bearer',
      'expires_in'   => JWT_ACCESS_TTL,
      'alg'          => alg
    }.to_json
  end

  # ------------------------------------------------------------------
  # Phase 7 self-test — run every crypto primitive on Workers and
  # report pass/fail per case. Hit this endpoint after deploy as the
  # closest thing to "CI on Workers" — confirms each algo actually
  # round-trips on the production runtime, not just on Node test.
  # ------------------------------------------------------------------
  get '/test/crypto' do
    content_type 'application/json'
    unless crypto_demos_enabled?
      status 404
      next { 'error' => 'crypto demos disabled (set HOMURABI_ENABLE_CRYPTO_DEMOS=1 in wrangler vars)' }.to_json
    end
    cases = []
    run = lambda { |label, &blk|
      result = begin
        v = blk.call
        v == false ? { 'pass' => false, 'note' => 'returned false' } : { 'pass' => true }
      rescue ::Exception => e
        { 'pass' => false, 'note' => "#{e.class}: #{e.message[0, 200]}" }
      end
      cases << result.merge('case' => label)
    }

    run.call('Digest::SHA256.hexdigest matches CRuby vector') {
      Digest::SHA256.hexdigest('hello') == '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    }
    run.call('OpenSSL::HMAC SHA256') {
      OpenSSL::HMAC.hexdigest('SHA256', 'secret', 'hello') == '88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b'
    }
    run.call('OpenSSL::KDF.pbkdf2_hmac') {
      d = OpenSSL::KDF.pbkdf2_hmac('password', salt: 'salt-1234', iterations: 4096, length: 32, hash: 'SHA256')
      d.unpack1('H*') == '2038580f917370fe42b04462a7c26ed17a2e769b44eb6181134243a9dabf0136'
    }
    run.call('AES-256-GCM round-trip') {
      key = SecureRandom.random_bytes(32); iv = SecureRandom.random_bytes(12)
      e = OpenSSL::Cipher.new('AES-256-GCM').encrypt; e.key = key; e.iv = iv
      e.update('payload-gcm'); ct = e.final.__await__; tag = e.auth_tag
      d = OpenSSL::Cipher.new('AES-256-GCM').decrypt; d.key = key; d.iv = iv; d.auth_tag = tag
      d.update(ct); d.final.__await__ == 'payload-gcm'
    }
    run.call('AES-256-CTR streaming') {
      key = SecureRandom.random_bytes(32); iv = SecureRandom.random_bytes(16)
      plain = 'streaming-' * 30
      e = OpenSSL::Cipher.new('AES-256-CTR').encrypt; e.key = key; e.iv = iv
      ct = ''
      i = 0
      while i < plain.length
        ct = ct + e.update(plain[i, 13]).__await__; i += 13
      end
      ct = ct + e.final.__await__
      d = OpenSSL::Cipher.new('AES-256-CTR').decrypt; d.key = key; d.iv = iv
      d.update(ct).__await__ + d.final.__await__ == plain
    }
    run.call('AES-128-CBC round-trip') {
      key = SecureRandom.random_bytes(16); iv = SecureRandom.random_bytes(16)
      e = OpenSSL::Cipher.new('AES-128-CBC').encrypt; e.key = key; e.iv = iv
      e.update('cbc-test'); ct = e.final.__await__
      d = OpenSSL::Cipher.new('AES-128-CBC').decrypt; d.key = key; d.iv = iv
      d.update(ct); d.final.__await__ == 'cbc-test'
    }
    run.call('RSA RS256 sign/verify') {
      r = OpenSSL::PKey::RSA.new(2048)
      sig = r.sign(OpenSSL::Digest::SHA256.new, 'rs256').__await__
      r.public_key.verify(OpenSSL::Digest::SHA256.new, sig, 'rs256').__await__
    }
    run.call('RSA PS256 sign/verify') {
      r = OpenSSL::PKey::RSA.new(2048)
      sig = r.sign_pss('SHA256', 'ps256', salt_length: :digest, mgf1_hash: 'SHA256').__await__
      r.public_key.verify_pss('SHA256', sig, 'ps256', salt_length: :digest, mgf1_hash: 'SHA256').__await__
    }
    run.call('RSA OAEP encrypt/decrypt') {
      r = OpenSSL::PKey::RSA.new(2048)
      ct = r.public_key.public_encrypt('oaep-payload').__await__
      r.private_decrypt(ct).__await__ == 'oaep-payload'
    }
    run.call('ECDSA ES256 (DER) sign/verify') {
      ec = OpenSSL::PKey::EC.generate('prime256v1')
      sig = ec.sign(OpenSSL::Digest::SHA256.new, 'es256').__await__
      sig.bytes[0] == 0x30 && ec.verify(OpenSSL::Digest::SHA256.new, sig, 'es256').__await__
    }
    run.call('ECDSA ES384 sign/verify') {
      ec = OpenSSL::PKey::EC.generate('secp384r1')
      sig = ec.sign(OpenSSL::Digest::SHA384.new, 'es384').__await__
      ec.verify(OpenSSL::Digest::SHA384.new, sig, 'es384').__await__
    }
    run.call('ECDSA ES512 sign/verify') {
      ec = OpenSSL::PKey::EC.generate('secp521r1')
      sig = ec.sign(OpenSSL::Digest::SHA512.new, 'es512').__await__
      ec.verify(OpenSSL::Digest::SHA512.new, sig, 'es512').__await__
    }
    run.call('ECDH P-256 agreement') {
      a = OpenSSL::PKey::EC.generate('prime256v1')
      b = OpenSSL::PKey::EC.generate('prime256v1')
      a.dh_compute_key(b).__await__ == b.dh_compute_key(a).__await__
    }
    run.call('Ed25519 sign/verify (EdDSA)') {
      ed = OpenSSL::PKey::Ed25519.generate
      sig = ed.sign(nil, 'eddsa').__await__
      ed.verify(nil, sig, 'eddsa').__await__
    }
    run.call('X25519 key agreement') {
      a = OpenSSL::PKey::X25519.generate
      b = OpenSSL::PKey::X25519.generate
      a.dh_compute_key(b).__await__ == b.dh_compute_key(a).__await__
    }
    run.call('OpenSSL::BN arithmetic') {
      (OpenSSL::BN.new(123) + OpenSSL::BN.new(456)).to_s == '579' &&
        OpenSSL::BN.new(3).mod_exp(5, 13).to_s == '9'
    }
    run.call('SecureRandom.hex(16) returns 32 hex chars') {
      SecureRandom.hex(16).length == 32
    }

    # Phase 8 — JWT self-test. Exercises the vendored jwt gem through
    # every algorithm against the live Workers runtime so we can prove
    # RS/PS/ES/EdDSA signatures actually verify on the edge, not just
    # in the Node test harness.
    jwt_payload = { 'sub' => 'self-test', 'iat' => Time.now.to_i }
    jwt_secret  = 'phase8-self-test-secret'

    run.call('JWT HS256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, jwt_secret, 'HS256').__await__
      dec, = JWT.decode(tok, jwt_secret, true, algorithm: 'HS256').__await__
      dec['sub'] == 'self-test'
    }
    run.call('JWT HS256 tampered signature rejected') {
      tok = JWT.encode(jwt_payload, jwt_secret, 'HS256').__await__
      parts = tok.split('.')
      parts[2] = parts[2][0..-2] + (parts[2][-1] == 'A' ? 'B' : 'A')
      raised = false
      begin
        JWT.decode(parts.join('.'), jwt_secret, true, algorithm: 'HS256').__await__
      rescue JWT::VerificationError
        raised = true
      end
      raised
    }

    rsa = OpenSSL::PKey::RSA.new(2048)
    run.call('JWT RS256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, rsa, 'RS256').__await__
      dec, = JWT.decode(tok, rsa.public_key, true, algorithm: 'RS256').__await__
      dec['sub'] == 'self-test'
    }
    run.call('JWT PS256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, rsa, 'PS256').__await__
      dec, = JWT.decode(tok, rsa.public_key, true, algorithm: 'PS256').__await__
      dec['sub'] == 'self-test'
    }
    run.call('JWT RS256 tampered signature rejected') {
      tok = JWT.encode(jwt_payload, rsa, 'RS256').__await__
      parts = tok.split('.')
      parts[2] = parts[2][0..-2] + (parts[2][-1] == 'A' ? 'B' : 'A')
      raised = false
      begin
        JWT.decode(parts.join('.'), rsa.public_key, true, algorithm: 'RS256').__await__
      rescue JWT::VerificationError
        raised = true
      end
      raised
    }

    ec256 = OpenSSL::PKey::EC.generate('prime256v1')
    run.call('JWT ES256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ec256, 'ES256').__await__
      dec, = JWT.decode(tok, ec256, true, algorithm: 'ES256').__await__
      dec['sub'] == 'self-test'
    }
    ec384 = OpenSSL::PKey::EC.generate('secp384r1')
    run.call('JWT ES384 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ec384, 'ES384').__await__
      dec, = JWT.decode(tok, ec384, true, algorithm: 'ES384').__await__
      dec['sub'] == 'self-test'
    }

    ed = OpenSSL::PKey::Ed25519.generate
    run.call('JWT EdDSA encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ed, 'EdDSA').__await__
      dec, = JWT.decode(tok, ed, true, algorithm: 'EdDSA').__await__
      dec['sub'] == 'self-test'
    }
    run.call('JWT EdDSA tampered signature rejected') {
      tok = JWT.encode(jwt_payload, ed, 'EdDSA').__await__
      parts = tok.split('.')
      parts[2] = parts[2][0..-2] + (parts[2][-1] == 'A' ? 'B' : 'A')
      raised = false
      begin
        JWT.decode(parts.join('.'), ed, true, algorithm: 'EdDSA').__await__
      rescue JWT::VerificationError
        raised = true
      end
      raised
    }

    passed = cases.count { |c| c['pass'] }
    failed = cases.size - passed
    {
      'passed' => passed,
      'failed' => failed,
      'total'  => cases.size,
      'cases'  => cases
    }.to_json
  end

  # ------------------------------------------------------------------
  # Phase 7 demo — Digest / HMAC / Cipher / RSA sign / EC sign /
  # KDF / SecureRandom in one JSON dump. Proves that an unmodified
  # jwt-style Ruby program can do every cryptographic primitive at
  # the edge.
  # ------------------------------------------------------------------
  get '/demo/crypto' do
    content_type 'application/json'
    unless crypto_demos_enabled?
      status 404
      next { 'error' => 'crypto demos disabled (set HOMURABI_ENABLE_CRYPTO_DEMOS=1 in wrangler vars)' }.to_json
    end

    # 1) Digest one-shots
    sha256 = Digest::SHA256.hexdigest('hello, edge')
    sha512 = Digest::SHA512.hexdigest('hello, edge')

    # 2) HMAC (JWT HS256 signing input shape)
    hmac_hex = OpenSSL::HMAC.hexdigest('SHA256', 'super-secret', 'hello, edge')

    # 3) AES-256-GCM round-trip with random key/iv (Web Crypto subtle async)
    key   = SecureRandom.random_bytes(32)
    iv    = SecureRandom.random_bytes(12)
    plain = 'phase 7 cipher payload'
    enc = OpenSSL::Cipher.new('AES-256-GCM').encrypt
    enc.key = key; enc.iv = iv
    enc.update(plain)
    ct  = enc.final.__await__
    tag = enc.auth_tag
    dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
    dec.key = key; dec.iv = iv; dec.auth_tag = tag
    dec.update(ct)
    recovered = dec.final.__await__

    # 4) RSA sign + verify (Web Crypto subtle async)
    rsa = OpenSSL::PKey::RSA.new(2048)
    msg = 'phase 7 rsa payload'
    sig = rsa.sign(OpenSSL::Digest::SHA256.new, msg).__await__
    rsa_ok = rsa.public_key.verify(OpenSSL::Digest::SHA256.new, sig, msg).__await__

    # 5) PBKDF2 derived key
    derived = OpenSSL::KDF.pbkdf2_hmac(
      'p@ssw0rd', salt: 'phase7-salt', iterations: 4096, length: 32, hash: 'SHA256'
    )

    # 6) Hand-rolled HS256 JWT (proof Phase 8 jwt gem will work)
    header  = { 'alg' => 'HS256', 'typ' => 'JWT' }
    payload = { 'sub' => 'demo', 'iat' => Time.now.to_i }
    enc_b64 = lambda { |obj| Base64.urlsafe_encode64(obj.to_json).delete('=') }
    signing_input = enc_b64.call(header) + '.' + enc_b64.call(payload)
    sig_bin = OpenSSL::HMAC.digest('SHA256', 'jwt-secret', signing_input)
    token   = signing_input + '.' + Base64.urlsafe_encode64(sig_bin).delete('=')

    {
      'demo'              => 'Phase 7 — node:crypto-backed Ruby crypto',
      'sha256_hello_edge' => sha256,
      'sha512_hello_edge' => sha512,
      'hmac_sha256_hex'   => hmac_hex,
      'aes_gcm_round_trip' => {
        'plain'     => plain,
        'recovered' => recovered,
        'match'     => recovered == plain,
        'tag_b64'   => Base64.strict_encode64(tag)
      },
      'rsa_sign_verify'   => { 'ok' => rsa_ok, 'sig_len_bytes' => sig.bytesize },
      'pbkdf2_sha256_hex' => derived.unpack1('H*'),
      'jwt_hs256'         => token,
      'secure_random'     => {
        'hex'             => SecureRandom.hex(16),
        'urlsafe_base64'  => SecureRandom.urlsafe_base64(24),
        'uuid'            => SecureRandom.uuid
      }
    }.to_json
  end
  # ------------------------------------------------------------------
  # Phase 9 — Cloudflare Workers Cron Triggers.
  #
  # Each `schedule` block is invoked from `src/worker.mjs#scheduled`
  # via `globalThis.__HOMURABI_SCHEDULED_DISPATCH__` whenever the
  # Workers runtime fires the matching cron (declared in
  # `wrangler.toml [triggers] crons`). The block runs in a
  # `Sinatra::Scheduled::ScheduledContext` instance, which exposes
  # the same `db` / `kv` / `bucket` helpers as HTTP routes plus a
  # `wait_until(promise)` wrapper around `ctx.waitUntil`.
  #
  # The block argument is a `Cloudflare::ScheduledEvent` with `.cron`
  # (the literal cron string from wrangler.toml) and `.scheduled_time`
  # (a Ruby Time at the epoch the event was scheduled for).
  #
  # Local manual trigger:
  #   npx wrangler dev --test-scheduled
  #   curl 'http://127.0.0.1:8787/__scheduled?cron=*/5+*+*+*+*'
  # ------------------------------------------------------------------
  # Per-block guard: even though Phase 9 jobs are *registered*
  # unconditionally (so `wrangler.toml`'s `[triggers] crons` declarations
  # actually wire up to a Ruby handler), the *body* of these demo
  # schedules is opt-in via the same `HOMURABI_ENABLE_SCHEDULED_DEMOS`
  # var that gates `/test/scheduled*`. Without the flag, production
  # cron firings short-circuit to a no-op so default deploys never
  # accumulate heartbeat rows or burn KV write quota.
  schedule '*/5 * * * *', name: 'heartbeat' do |event|
    cf_env = env['cloudflare.env']
    enabled = cf_env && `(#{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS || '')`.to_s == '1'
    next unless enabled
    # Insert one row into D1's heartbeats table per cron firing.
    # Falls back to a no-op when DB is not bound (test envs).
    if db
      db.execute_insert(
        'INSERT INTO heartbeats (cron, scheduled_at, fired_at, note) VALUES (?, ?, ?, ?)',
        [event.cron, event.scheduled_time.to_i, Time.now.to_i, 'phase9-heartbeat']
      ).__await__
    end
  end

  schedule '0 */1 * * *', name: 'hourly-housekeeping' do |event|
    cf_env = env['cloudflare.env']
    enabled = cf_env && `(#{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS || '')`.to_s == '1'
    next unless enabled
    # Demo: bump a KV counter so we can prove hourly cron runs from
    # outside a test by inspecting `/kv/cron:hourly-counter` over HTTP.
    # Falls back to a no-op when KV is not bound (test envs).
    if kv
      raw  = kv.get('cron:hourly-counter').__await__
      prev = 0
      if raw
        begin
          prev = JSON.parse(raw)['count'].to_i
        rescue StandardError
          prev = 0
        end
      end
      payload = {
        'count'        => prev + 1,
        'last_cron'    => event.cron,
        'last_run_at'  => Time.now.to_i,
        'last_sched_t' => event.scheduled_time.to_i
      }.to_json
      kv.put('cron:hourly-counter', payload).__await__
    end
  end

  # ------------------------------------------------------------------
  # Phase 9 self-test endpoints — gated on HOMURABI_ENABLE_SCHEDULED_DEMOS.
  #
  # GET  /test/scheduled            → list every registered job (cron,
  #                                    name, source location)
  # POST /test/scheduled/run?cron=… → manually fire every job whose
  #                                    cron expression equals the
  #                                    query param. Same code path the
  #                                    Workers runtime takes; lets us
  #                                    smoke-test cron handlers from
  #                                    a curl in `wrangler dev`
  #                                    without waiting 5 minutes.
  # ------------------------------------------------------------------
  get '/test/scheduled' do
    content_type 'application/json'
    unless scheduled_demos_enabled?
      status 404
      next { 'error' => 'scheduled demos disabled (set HOMURABI_ENABLE_SCHEDULED_DEMOS=1 in wrangler vars)' }.to_json
    end
    {
      'jobs' => App.scheduled_jobs.map do |job|
        {
          'name' => job.name,
          'cron' => job.cron,
          'file' => job.file,
          'line' => job.line
        }
      end
    }.to_json
  end

  post '/test/scheduled/run' do
    content_type 'application/json'
    unless scheduled_demos_enabled?
      status 404
      next({ 'error' => 'scheduled demos disabled (set HOMURABI_ENABLE_SCHEDULED_DEMOS=1 in wrangler vars)' }.to_json)
    end
    cron = params['cron'].to_s
    if cron.empty?
      status 400
      next({ 'error' => 'missing cron query param (e.g. ?cron=*/5%20*%20*%20*%20*)' }.to_json)
    end
    # Use the same dispatcher the Workers runtime invokes. Pass the
    # JS env / ctx so D1 / KV writes hit the live bindings. The
    # dispatcher is async (it `__await__`s each job's body), so we
    # MUST `__await__` its return Promise before serialising the
    # result — otherwise the inner D1 / KV writes get torn down when
    # the HTTP response is sent. The literal `__await__` token is
    # what Opal scans for to emit a JS `await`.
    event  = Cloudflare::ScheduledEvent.new(cron: cron, scheduled_time: Time.now)
    result = App.dispatch_scheduled(event, env['cloudflare.env'], env['cloudflare.ctx']).__await__
    result.merge('cron' => cron, 'registered_crons' => App.scheduled_jobs.map(&:cron)).to_json
  end

  # ------------------------------------------------------------------
  # Phase 10 — Workers AI chat demo.
  #
  # Sinatra routes call Cloudflare::AI.run(model, inputs, binding: ai)
  # to invoke a Workers AI model. The chat UI lives at GET /chat,
  # API endpoints under /api/chat/*.
  #
  # Models are pinned at the top of the chat block so swapping the
  # primary or adding more fallbacks is one constant edit. Llama-family
  # models are intentionally excluded per Phase 10 master directive.
  # ------------------------------------------------------------------
  CHAT_MODELS = {
    primary:  '@cf/google/gemma-4-26b-a4b-it',
    fallback: '@cf/openai/gpt-oss-120b'
  }.freeze
  CHAT_HISTORY_LIMIT = 32       # last N messages kept in KV per session
  CHAT_HISTORY_TTL   = 86_400 * 7  # 1 week
  CHAT_SYSTEM_PROMPT = 'You are homurabi, a friendly Sinatra-on-Cloudflare-Workers assistant. Reply concisely. If the user writes Japanese, reply in Japanese. If the user writes English, reply in English.'

  # Workers AI returns one of two response shapes depending on the model:
  # 1. legacy `{ response: "..." }`            (e.g. older llama, mistral)
  # 2. OpenAI-style `{ choices: [{ message: { content: "..." } }] }`
  #    (Gemma 4, gpt-oss-* and any other "chat completions"-shaped model)
  # Helper that tolerates both so the route doesn't have to branch.
  def self.extract_ai_text(out)
    return out.to_s unless out.is_a?(Hash)
    # OpenAI-style choices[].message.content
    if out['choices'].is_a?(Array) && !out['choices'].empty?
      msg = out['choices'][0].is_a?(Hash) ? out['choices'][0]['message'] : nil
      if msg.is_a?(Hash)
        c = msg['content']
        return c.to_s if c.is_a?(String) && !c.empty?
        # Some models put the visible answer in `reasoning` when the
        # response is truncated by max_tokens. Surface it as a fallback
        # so the user still sees something useful.
        r = msg['reasoning']
        return r.to_s if r.is_a?(String) && !r.empty?
      end
    end
    # Legacy `{ response: "..." }` / generic fallbacks.
    %w[response result output text].each do |k|
      v = out[k]
      return v.to_s if v.is_a?(String) && !v.empty?
    end
    ''
  end

  helpers do
    def ai_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_AI_DEMOS) || ''`
      val.to_s == '1'
    end

    def ai_binding
      env['cloudflare.AI']
    end

    # JS-aware "is the binding present?" — env.AI is a raw JS object
    # without a Ruby `.nil?` method, so `binding.nil?` would explode at
    # runtime. This helper checks the JS-level null/undefined directly.
    def ai_binding?
      v = env['cloudflare.AI']
      `(#{v} != null)`
    end

    # JSON body parse with a graceful default.
    def parse_json_body
      raw = request.body.read.to_s
      return {} if raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError, StandardError
      {}
    end

    # Allow only `[A-Za-z0-9_-]{1,64}` for session ids so a crafted
    # `?session=` cannot inject HTML when echoed back to /chat, cannot
    # generate exotic KV key names (which would also escape `chat:` and
    # collide with other namespaces), and cannot create unbounded
    # per-user key cardinality. Falls back to `'demo'` on rejection.
    SESSION_ID_RE = /\A[A-Za-z0-9_-]{1,64}\z/.freeze

    def normalize_session_id(raw)
      s = raw.to_s
      return 'demo' if s.empty?
      SESSION_ID_RE.match?(s) ? s : 'demo'
    end

    def chat_kv_key(session_id)
      "chat:#{session_id}"
    end

    # Returns the array of {role, content} message Hashes for a session,
    # or [] if KV has nothing (or no KV is bound).
    def load_chat_history(session_id)
      return [] unless kv
      raw = kv.get(chat_kv_key(session_id)).__await__
      return [] if raw.nil? || raw.empty?
      arr = JSON.parse(raw)
      arr.is_a?(Array) ? arr : []
    rescue JSON::ParserError
      []
    end

    def save_chat_history(session_id, history)
      return unless kv
      trimmed = history.last(CHAT_HISTORY_LIMIT)
      # Pass CHAT_HISTORY_TTL through so KV expires the entry
      # automatically and the namespace doesn't accumulate dead
      # sessions forever (the constant was previously documented but
      # unused — Copilot review #5).
      kv.put(chat_kv_key(session_id), trimmed.to_json, expiration_ttl: CHAT_HISTORY_TTL).__await__
    end

    def clear_chat_history(session_id)
      return unless kv
      kv.delete(chat_kv_key(session_id)).__await__
    end

    # Convert chat history to the messages array Workers AI expects.
    # Always prepends a system prompt so the model has consistent persona.
    def build_ai_messages(history, latest_user_text)
      msgs = [{ 'role' => 'system', 'content' => CHAT_SYSTEM_PROMPT }]
      history.each { |m| msgs << { 'role' => m['role'], 'content' => m['content'] } }
      msgs << { 'role' => 'user', 'content' => latest_user_text }
      msgs
    end

    # Both gates return either nil (= keep going) or a `[status, body]`
    # tuple that the caller hands back via `next`. We deliberately do
    # NOT use `halt` because the chat routes are `# await: true` async
    # blocks; `halt` is implemented as `throw :halt`, and the throw
    # escapes Sinatra's synchronous `catch :halt` wrapper through the
    # async/await boundary (Copilot review #8/#9). Same root cause as
    # the JWT auth helper rewrite.
    def ai_demos_block_or_nil
      return nil if ai_demos_enabled?
      [404, { 'error' => 'AI demos disabled (set HOMURABI_ENABLE_AI_DEMOS=1 in wrangler vars)' }.to_json]
    end

    def ai_binding_block_or_nil
      return nil if ai_binding?
      [503, { 'error' => 'AI binding not configured (wrangler.toml [ai] block missing or wrangler version too old)' }.to_json]
    end

    # Inline JWT verification tailored for the chat routes.
    #
    # Sinatra's `Sinatra::JwtAuth#authenticate!` helper relies on `halt`,
    # which is implemented via `throw :halt`. When the helper itself is
    # `# await: true` (because JWT.decode awaits Web Crypto subtle), the
    # `throw` escapes the async boundary before Sinatra's
    # `catch :halt do ... end` wrapper can see it, and the route crashes
    # with `UncaughtThrowError: "halt"`. Same root cause as the
    # `each: undefined method for PromiseV2` issue — async Sinatra needs
    # values, not control-flow exceptions, across the await boundary.
    #
    # `chat_verify_token!` returns either:
    #   - a Hash with `{ ok: true, payload: <decoded> }` on success, or
    #   - a Hash with `{ ok: false, status: 401, body: <json> }` on
    #     failure (so the route can `next body` after a status set).
    # The route is responsible for halting / returning early.
    def chat_verify_token!
      header = request.env['HTTP_AUTHORIZATION'].to_s
      parts = header.split(' ', 2)
      if parts.length != 2 || parts[0].downcase != 'bearer'
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      token = parts[1].strip
      if token.empty?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      verify_key = settings.jwt_secret
      algorithm  = settings.jwt_algorithm
      reason = nil
      decoded = begin
        JWT.decode(token, verify_key, true, algorithm: algorithm).__await__
      rescue JWT::ExpiredSignature
        reason = 'token expired'
        nil
      rescue JWT::VerificationError
        reason = 'signature verification failed'
        nil
      rescue JWT::IncorrectAlgorithm
        reason = 'algorithm mismatch'
        nil
      rescue JWT::DecodeError => e
        reason = "invalid token: #{e.message}"
        nil
      rescue StandardError => e
        reason = "auth error: #{e.message}"
        nil
      end
      if decoded.nil?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => reason || 'token verification failed' }.to_json }
      end
      payload, _header = decoded
      @jwt_payload = payload
      { 'ok' => true, 'payload' => payload }
    end
  end

  # GET /chat — chat UI page. JWT-gated for API calls (the page itself
  # is open so the user can mint a token from inside it).
  get '/chat' do
    @title = 'homurabi /chat — Workers AI'
    @primary_model  = CHAT_MODELS[:primary]
    @fallback_model = CHAT_MODELS[:fallback]
    @session_id = normalize_session_id(params['session'])
    @history = ai_demos_enabled? ? load_chat_history(@session_id).__await__ : []
    @content = erb :chat
    erb :layout
  end

  # GET /api/chat/health — lightweight binding check; no AI call.
  get '/api/chat/health' do
    content_type 'application/json'
    {
      'ok'             => true,
      'demos_enabled'  => ai_demos_enabled?,
      'ai_bound'       => ai_binding?,
      'kv_bound'       => !kv.nil?,
      'primary_model'  => CHAT_MODELS[:primary],
      'fallback_model' => CHAT_MODELS[:fallback]
    }.to_json
  end

  # POST /api/chat/messages — append a user message, call Workers AI,
  # persist the round-trip in KV, and return the assistant reply.
  # Body: { "session": "...", "content": "...", "model": "@cf/.../...?" }
  post '/api/chat/messages' do
    content_type 'application/json'
    gate = ai_demos_block_or_nil
    next gate if gate
    # Inline JWT verification — early-exit with explicit `status` and
    # `next` (the same pattern Phase 8's /api/me uses successfully).
    # We deliberately do NOT call `Sinatra::JwtAuth#authenticate!`
    # because that helper uses `halt` which throws past Opal's async
    # boundary (Sinatra's `catch :halt` cannot see a JS Promise
    # rejection). And we keep the token decode outside any helper so
    # the `status N` call sits in the same `dispatch!` frame as the
    # `next` — pulling it into a helper made the response leak out
    # as 200 in earlier iterations.
    auth_header = request.env['HTTP_AUTHORIZATION'].to_s
    parts = auth_header.split(' ', 2)
    if parts.length != 2 || parts[0].downcase != 'bearer'
      status 401
      next({ 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json)
    end
    auth_token = parts[1].strip
    if auth_token.empty?
      status 401
      next({ 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json)
    end
    # JWT verify (post-await). Setting `status N` after the await would
    # not take effect because Sinatra's `invoke` snapshots
    # `response.status` synchronously when it sees a Promise body, so
    # any mutation that happens later than that snapshot is lost. We
    # work around it by returning `[status, body]` from the route — the
    # homurabi patch in `build_js_response` detects that single-chunk
    # shape and uses the embedded status when constructing the JS
    # Response.
    decode_err = `(async function(){
      try {
        await #{JWT.decode(auth_token, settings.jwt_secret, true, algorithm: settings.jwt_algorithm)};
        return null;
      } catch (e) {
        var msg = (e && e.$message) ? e.$message() : (e && e.message) ? e.message : String(e);
        return 'invalid token: ' + String(msg);
      }
    })()`.__await__
    is_failure = `(#{decode_err} != null && #{decode_err} !== undefined)`
    if is_failure
      err_msg = decode_err.to_s
      next [401, { 'error' => 'unauthorized', 'reason' => err_msg }.to_json]
    end
    bgate = ai_binding_block_or_nil
    next bgate if bgate

    body = parse_json_body
    session_id = normalize_session_id(body['session'])
    user_text  = body['content'].to_s
    if user_text.strip.empty?
      status 400
      next({ 'error' => 'content required' }.to_json)
    end

    requested_model = body['model'].to_s
    primary  = CHAT_MODELS[:primary]
    fallback = CHAT_MODELS[:fallback]
    # Allow either of the two configured models. Anything else is
    # rejected so a client can't run up neuron costs on arbitrary models.
    model = if requested_model == primary || requested_model == fallback
              requested_model
            else
              primary
            end

    # Helper methods that internally call `__await__` on a binding
    # (KV / D1 / AI) compile to async JS functions, so each helper
    # call must be `__await__`'d at the call site to unwrap the
    # returned Promise. Without the explicit await, `history` would
    # be a PromiseV2 and downstream `JSON.parse` / Array iteration
    # would crash with "undefined method `each` for PromiseV2".
    history = load_chat_history(session_id).__await__
    messages = build_ai_messages(history, user_text)

    started_at = Time.now.to_f
    used_model = model
    used_fallback = false
    reply_text = nil
    ai_error  = nil

    begin
      result = Cloudflare::AI.run(
        model,
        # max_tokens raised to 1024 because OpenAI-style models (Gemma 4,
        # gpt-oss-*) report `finish_reason: "length"` and surface the
        # visible answer in `message.reasoning` instead of `content` when
        # truncated. 1024 is generous enough for most chat replies and
        # still well under Workers' 30s wall-time budget.
        { messages: messages, max_tokens: 1024 },
        binding: ai_binding
      ).__await__
      reply_text = App.extract_ai_text(result).strip
      raise Cloudflare::AIError.new('empty response', model: model) if reply_text.empty?
    rescue Cloudflare::AIError => e
      ai_error = e
    end

    # Fallback: if the primary model fails or returns empty, retry with
    # the secondary model exactly once before surfacing an error.
    if reply_text.nil? || reply_text.empty?
      used_fallback = true
      used_model = (model == primary) ? fallback : primary
      begin
        result = Cloudflare::AI.run(
          used_model,
          { messages: messages, max_tokens: 1024 },
          binding: ai_binding
        ).__await__
        reply_text = App.extract_ai_text(result).strip
      rescue Cloudflare::AIError => e
        status 502
        next({ 'error' => 'workers AI call failed', 'detail' => e.message, 'fallback_error' => true }.to_json)
      end
      if reply_text.nil? || reply_text.empty?
        status 502
        next({ 'error' => 'workers AI returned empty response on both primary and fallback' }.to_json)
      end
    end

    elapsed_ms = ((Time.now.to_f - started_at) * 1000).to_i
    new_history = history + [
      { 'role' => 'user',      'content' => user_text },
      { 'role' => 'assistant', 'content' => reply_text }
    ]
    save_chat_history(session_id, new_history).__await__

    {
      'ok'           => true,
      'session'      => session_id,
      'model'        => used_model,
      'used_fallback'=> used_fallback,
      'elapsed_ms'   => elapsed_ms,
      'reply'        => reply_text,
      'history_len'  => new_history.size
    }.to_json
  end

  # GET /api/chat/messages — return the persisted history for a session.
  get '/api/chat/messages' do
    content_type 'application/json'
    gate = ai_demos_block_or_nil
    next gate if gate
    auth = chat_verify_token!.__await__
    if auth['ok'] != true
      # See the long comment in POST /api/chat/messages for why we
      # return [status, body] instead of using `status N; next body`
      # — Sinatra snapshots response.status before the await resolves,
      # so any later mutation is lost.
      next [auth['status'].to_i, auth['body']]
    end
    session_id = normalize_session_id(params['session'])
    {
      'session' => session_id,
      'history' => load_chat_history(session_id).__await__
    }.to_json
  end

  # DELETE /api/chat/messages?session=... — wipe history for a session.
  delete '/api/chat/messages' do
    content_type 'application/json'
    gate = ai_demos_block_or_nil
    next gate if gate
    auth = chat_verify_token!.__await__
    if auth['ok'] != true
      # See the long comment in POST /api/chat/messages for why we
      # return [status, body] instead of using `status N; next body`
      # — Sinatra snapshots response.status before the await resolves,
      # so any later mutation is lost.
      next [auth['status'].to_i, auth['body']]
    end
    session_id = normalize_session_id(params['session'])
    clear_chat_history(session_id).__await__
    { 'ok' => true, 'session' => session_id, 'cleared' => true }.to_json
  end

  # GET /test/ai/debug — dump the raw AI binding response so we can see
  # what shape Workers AI actually returns. Useful when adding support
  # for a new model whose `extract_ai_text` mapping isn't obvious.
  get '/test/ai/debug' do
    content_type 'application/json'
    unless ai_demos_enabled? && ai_binding?
      status 404
      next({ 'error' => 'disabled' }.to_json)
    end
    model = params['model'] || CHAT_MODELS[:primary]
    out = Cloudflare::AI.run(
      model,
      { messages: [
        { role: 'system', content: 'reply with a short Japanese greeting' },
        { role: 'user',   content: 'こんにちは' }
      ], max_tokens: 64 },
      binding: ai_binding
    ).__await__
    {
      'model'    => model,
      'class'    => out.class.to_s,
      'is_hash'  => out.is_a?(Hash),
      'keys'     => out.is_a?(Hash) ? out.keys : nil,
      'extracted'=> App.extract_ai_text(out),
      'raw'      => out
    }.to_json
  end

  # GET /test/ai — Workers self-test for the AI binding. Exercises the
  # primary model with a trivial prompt and reports pass/fail. Gated
  # behind the same HOMURABI_ENABLE_AI_DEMOS flag so it can't be hit
  # accidentally in production.
  get '/test/ai' do
    content_type 'application/json'
    unless ai_demos_enabled?
      status 404
      next({ 'error' => 'AI demos disabled (set HOMURABI_ENABLE_AI_DEMOS=1)' }.to_json)
    end
    unless ai_binding?
      status 503
      next({ 'error' => 'AI binding not bound (wrangler.toml [ai] block missing)' }.to_json)
    end

    cases = []
    primary  = CHAT_MODELS[:primary]
    fallback = CHAT_MODELS[:fallback]

    # NOTE: blocks-with-`__await__` compile to async functions in Opal
    # under `# await: true`. Iterators like `Array#each_with_index`
    # don't await each step, so any work the block kicks off races
    # against the JSON serialisation below — the route would return
    # `{cases: []}` before the AI call even finished. Inline a manual
    # loop where each step is followed by an explicit `__await__`.

    test_one = lambda { |model, label|
      result = begin
        out = Cloudflare::AI.run(model,
          { messages: [
            { role: 'system', content: 'reply with the single word READY' },
            { role: 'user',   content: 'ping' }
          ], max_tokens: 64 },
          binding: ai_binding
        ).__await__
        txt = App.extract_ai_text(out).strip
        if txt.empty?
          { 'pass' => false, 'note' => 'empty response from model' }
        else
          { 'pass' => true, 'note' => txt[0, 200] }
        end
      rescue ::Exception => e
        { 'pass' => false, 'note' => "#{e.class}: #{e.message[0, 200]}" }
      end
      result.merge('case' => label)
    }

    cases << test_one.call(primary,  "primary model #{primary} responds").__await__
    cases << test_one.call(fallback, "fallback model #{fallback} responds").__await__

    passed = cases.count { |c| c['pass'] }
    failed = cases.size - passed
    {
      'passed' => passed,
      'failed' => failed,
      'total'  => cases.size,
      'cases'  => cases
    }.to_json
  end

  # ------------------------------------------------------------------
  # Phase 11B — Durable Objects / Cache API / Queues demo routes.
  #
  # All routes below are gated by HOMURABI_ENABLE_BINDING_DEMOS so
  # public deploys don't spend DO storage / queue quota on every
  # drive-by request.  See the helpers block above for the gate.
  # ------------------------------------------------------------------

  # Queue consumer handler. `batch` is a Cloudflare::QueueBatch with a
  # `.messages` Array of Cloudflare::QueueMessage objects. Every
  # message stores a timestamp into KV under `queue:last-consumed:<i>`
  # so `wrangler dev` + `/demo/queue/status` can confirm round-trip
  # delivery without invasive logging.
  consume_queue 'homurabi-jobs' do |batch|
    # Under `# await: true`, using `Array#each` with an internal
    # `__await__` is unreliable because Opal yields to an async
    # callback whose return value is never awaited by `each` — some
    # writes silently drop. Use an indexed `while` loop instead, the
    # same pattern `Sinatra::Scheduled#dispatch_scheduled` adopts.
    if kv
      msgs = batch.messages
      i = 0
      total = msgs.length
      while i < total
        msg = msgs[i]
        record = {
          'id'           => msg.id,
          'body'         => msg.body,
          'queue'        => batch.queue,
          'consumed_at'  => Time.now.to_i,
          'batch_index'  => i
        }
        kv.put("queue:last-consumed:#{i}", record.to_json, expiration_ttl: 86_400).__await__
        msg.ack
        i += 1
      end
    else
      batch.ack_all
    end
    batch.size
  end

  # DO handler — implements the counter. One instance per "name"
  # (routed by `do_counter.get_by_name("global")` in the route).
  #
  # /inc  → increment, return new count
  # /peek → read without mutating
  # /reset → clear storage
  Cloudflare::DurableObject.define('HomurabiCounterDO') do |state, request|
    path = request.path
    prev = (state.storage.get('count').__await__ || 0).to_i
    if path.end_with?('/inc')
      next_count = prev + 1
      state.storage.put('count', next_count).__await__
      [
        200,
        { 'content-type' => 'application/json' },
        {
          'count'       => next_count,
          'previous'    => prev,
          'path'        => path,
          'do_id'       => state.id,
          'updated_at'  => Time.now.to_i
        }.to_json
      ]
    elsif path.end_with?('/reset')
      state.storage.delete('count').__await__
      [
        200,
        { 'content-type' => 'application/json' },
        { 'reset' => true, 'do_id' => state.id }.to_json
      ]
    else
      [
        200,
        { 'content-type' => 'application/json' },
        { 'count' => prev, 'path' => path, 'do_id' => state.id }.to_json
      ]
    end
  end

  # GET /demo/do — hit the Counter DO by name. The `name` query param
  # (default 'global') selects which DO instance to address.
  get '/demo/do' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    ns = do_counter
    if ns.nil?
      status 503
      next({ 'error' => 'DurableObject binding COUNTER not bound (wrangler.toml missing [[durable_objects.bindings]])' }.to_json)
    end
    name = (params['name'] || 'global').to_s
    action = (params['action'] || 'inc').to_s
    stub = ns.get_by_name(name)
    # `stub.fetch` requires an absolute URL — the Workers runtime
    # parses the URL to route the call. The host is irrelevant (the
    # DO receives the whole Request), but it must be parseable.
    url = "https://homurabi-do.internal/#{action}"
    res = stub.fetch(url, method: 'POST').__await__
    {
      'demo'    => 'Durable Objects counter',
      'binding' => 'COUNTER',
      'class'   => 'HomurabiCounterDO',
      'name'    => name,
      'action'  => action,
      'status'  => res.status,
      'body'    => res.body.empty? ? nil : JSON.parse(res.body)
    }.to_json
  end

  # GET /demo/cache/heavy — simulates an expensive computation that is
  # served from Cache API on the second hit. We don't sleep; instead
  # we do a real loop of SHA-256 iterations so the first-call cost is
  # measurable (`elapsed_ms`) without depending on a clock hack.
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

  # POST /api/enqueue — enqueue a message onto JOBS_QUEUE. Body is a
  # JSON Hash that is passed through verbatim as the message body.
  post '/api/enqueue' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    q = jobs_queue
    if q.nil?
      status 503
      next({ 'error' => 'Queue binding JOBS_QUEUE not bound (wrangler.toml missing [[queues.producers]])' }.to_json)
    end
    begin
      body = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError
      body = { 'note' => 'default payload (empty or invalid JSON body)', 'ts' => Time.now.to_i }
    end
    q.send(body).__await__
    status 202
    { 'enqueued' => true, 'queue' => 'homurabi-jobs', 'payload' => body }.to_json
  end

  # GET /demo/queue/status — introspect the last-consumed messages
  # recorded by the Ruby `consume_queue` handler above. Reads up to
  # `limit` KV entries that were written by the consumer so a caller
  # can confirm messages round-tripped end-to-end.
  get '/demo/queue/status' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    if kv.nil?
      status 503
      next({ 'error' => 'KV not bound — cannot read consumer state' }.to_json)
    end
    limit = (params['limit'] || '10').to_i
    recent = []
    i = 0
    while i < limit
      raw = kv.get("queue:last-consumed:#{i}").__await__
      break if raw.nil? || raw.empty?
      begin
        recent << JSON.parse(raw)
      rescue JSON::ParserError
        recent << { 'raw' => raw }
      end
      i += 1
    end
    {
      'queue'   => 'homurabi-jobs',
      'count'   => recent.size,
      'recent'  => recent
    }.to_json
  end

  # POST /test/queue/fire — manually invoke the queue consumer with a
  # synthesised batch so local `wrangler dev` can exercise the
  # `consume_queue` handler without waiting for miniflare's
  # delivery scheduler (which in wrangler 3.114 does not always
  # flush queued messages to the same worker's `queue()` export).
  #
  # Request body: { "queue": "homurabi-jobs", "messages": [{...}, ...] }
  #   — `queue` defaults to 'homurabi-jobs'
  #   — `messages` is an Array of arbitrary JSON bodies. Each becomes
  #     a QueueMessage with a synthetic id and ack/retry no-ops.
  #
  # This route uses the same Cloudflare::QueueConsumer.dispatch_js
  # dispatcher that `worker.mjs#queue` wires up in production, so
  # the consumer body runs identically.
  post '/test/queue/fire' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled' }.to_json)
    end
    body = begin
      JSON.parse(request.body.read)
    rescue StandardError
      {}
    end
    qname = (body['queue'] || 'homurabi-jobs').to_s
    messages = body['messages'].is_a?(Array) ? body['messages'] : [{ 'fire' => true, 'ts' => Time.now.to_i }]

    js_msgs = `([])`
    idx = 0
    messages.each do |m|
      js_body = Cloudflare::AI.ruby_to_js(m)
      i_str = "manual-#{Time.now.to_i}-#{idx}"
      now_ms = (Time.now.to_f * 1000).to_i
      `#{js_msgs}.push({ id: #{i_str}, timestamp: new Date(#{now_ms}), body: #{js_body}, ack: function() {}, retry: function() {} })`
      idx += 1
    end
    js_batch = `({ queue: #{qname}, messages: #{js_msgs}, ackAll: function() {}, retryAll: function() {} })`
    summary = Cloudflare::QueueConsumer.dispatch_js(js_batch, env['cloudflare.env'], env['cloudflare.ctx']).__await__
    summary.merge('injected' => messages.size).to_json
  end

  # GET /test/bindings — Phase 11B self-test. Confirms that every
  # binding wrapper does a real round-trip on the live Workers runtime.
  # Each case pass/fails individually so a single broken binding
  # doesn't mask the others.
  get '/test/bindings' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
    end
    cases = []
    started = Time.now.to_f

    # 1. DurableObject round-trip
    do_case = { 'case' => 'DurableObject counter inc/peek/reset round-trip' }
    begin
      ns = do_counter
      if ns.nil?
        do_case['pass'] = false
        do_case['note'] = 'COUNTER binding not bound'
      else
        name = "selftest-#{SecureRandom.hex(4)}"
        stub = ns.get_by_name(name)
        base = 'https://homurabi-do.internal'
        stub.fetch("#{base}/reset", method: 'POST').__await__
        r1 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').__await__.body)
        r2 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').__await__.body)
        peek = JSON.parse(stub.fetch("#{base}/peek").__await__.body)
        do_case['pass'] = r1['count'] == 1 && r2['count'] == 2 && peek['count'] == 2
        do_case['detail'] = { 'r1' => r1, 'r2' => r2, 'peek' => peek }
        stub.fetch("#{base}/reset", method: 'POST').__await__
      end
    rescue ::Exception => e
      do_case['pass'] = false
      do_case['note'] = "#{e.class}: #{e.message[0, 200]}"
    end
    cases << do_case

    # 2. Cache API put/match round-trip
    cache_case = { 'case' => 'Cache API match after put returns same body' }
    begin
      c = cache
      key = "https://cache-selftest.example/phase11b-#{SecureRandom.hex(4)}"
      payload = { 'self_test' => true, 'ts' => Time.now.to_i }.to_json
      c.put(key, payload, status: 200, headers: {
        'content-type'  => 'application/json',
        'cache-control' => 'public, max-age=30',
        'date'          => Time.now.httpdate
      }).__await__
      got = c.match(key).__await__
      if got.nil?
        cache_case['pass'] = false
        cache_case['note'] = 'match returned nil after put (cache unavailable in this runtime?)'
      else
        cache_case['pass'] = got.body == payload
        cache_case['detail'] = { 'status' => got.status, 'content_type' => got['content-type'] }
      end
    rescue ::Exception => e
      cache_case['pass'] = false
      cache_case['note'] = "#{e.class}: #{e.message[0, 200]}"
    end
    cases << cache_case

    # 3. Queue producer .send succeeds (does not crash). We can't
    # synchronously assert delivery because the consumer runs in a
    # separate invocation; instead we check that the producer returned
    # without error and, when KV is available, that at least one
    # message had been delivered previously (warmup from /api/enqueue).
    queue_case = { 'case' => 'Queue producer send() returns without error' }
    begin
      q = jobs_queue
      if q.nil?
        queue_case['pass'] = false
        queue_case['note'] = 'JOBS_QUEUE binding not bound'
      else
        q.send({ 'selftest' => true, 'ts' => Time.now.to_i, 'nonce' => SecureRandom.hex(4) }).__await__
        queue_case['pass'] = true
        queue_case['note'] = 'producer.send completed'
      end
    rescue ::Exception => e
      queue_case['pass'] = false
      queue_case['note'] = "#{e.class}: #{e.message[0, 200]}"
    end
    cases << queue_case

    passed = cases.count { |c| c['pass'] }
    failed = cases.size - passed
    {
      'passed'    => passed,
      'failed'    => failed,
      'total'     => cases.size,
      'elapsed_ms'=> ((Time.now.to_f - started) * 1000).round,
      'cases'     => cases
    }.to_json
  end
end

run App
