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
require 'sinatra/base'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'base64'
require 'jwt'
require 'sinatra/jwt_auth'

class App < Sinatra::Base
  # Phase 8 — JWT auth. The secret is the default HS256 path; asymmetric
  # algo demos generate their own keys on first use and cache them in
  # class-level ivars so repeat requests don't pay the 2048-bit RSA
  # generation cost. The secret is deterministic only for local dev —
  # in production it should come from a Workers secret (wrangler secret
  # put JWT_SECRET) pulled via `env['cloudflare.env'].JWT_SECRET`.
  register Sinatra::JwtAuth
  set :jwt_secret, 'homurabi-phase8-demo-secret-change-me-in-prod'
  set :jwt_algorithm, 'HS256'
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

    # Refresh token: opaque random string. Store in KV keyed by the
    # token itself with the user info + expiry; opaque-only means a
    # stolen refresh_token cannot be reversed into user claims.
    refresh = SecureRandom.urlsafe_base64(48)
    if kv
      entry = { 'sub' => username, 'alg' => alg, 'exp' => Time.now.to_i + JWT_REFRESH_TTL }
      kv.put("refresh:#{refresh}", entry.to_json).__await__
    end

    status 201
    {
      'access_token'  => access_token,
      'token_type'    => 'Bearer',
      'expires_in'    => JWT_ACCESS_TTL,
      'alg'           => alg,
      'refresh_token' => refresh
    }.to_json
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
    alg   = alg_from_token(token)
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
end

run App
