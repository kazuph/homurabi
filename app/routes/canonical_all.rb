# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route table — loaded inside `class App < Sinatra::Base` (order = original hello.rb)
  get '/' do
    @title = 'Hello from Sinatra'
    @users = db ? db.execute('SELECT id, name FROM users ORDER BY id') : []
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
  post '/api/echo' do
    content_type 'application/json'
    request.body.rewind
    body = request.body.read
    "{\"echo\": \"#{body}\"}"
  end
  get '/d1/users' do
    content_type 'application/json'
    db.execute('SELECT id, name FROM users ORDER BY id').to_json
  end
  get '/d1/users/:id' do
    content_type 'application/json'
    id = params['id'].to_i
    row = db.get_first_row('SELECT id, name FROM users WHERE id = ?', [id])
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
      row = db.get_first_row('INSERT INTO users (name) VALUES (?) RETURNING id, name', [name])
      status 201
      row.to_json
    end
  end
  get '/demo/sequel' do
    content_type 'application/json'
    seq_db = Sequel.connect(adapter: :d1, d1: db)
    rows = seq_db[:users].order(:id).limit(10).all
    { 'rows' => rows, 'adapter' => 'sequel-d1', 'dialect' => 'sqlite' }.to_json
  end
  get '/demo/sequel/sql' do
    content_type 'application/json'
    seq_db = Sequel.connect(adapter: :d1, d1: db)
    ds = seq_db[:users].where(active: true).order(:name).limit(10)
    { 'sql' => ds.sql.to_s, 'adapter' => 'sequel-d1' }.to_json
  end
  get '/posts' do
    content_type 'application/json'
    seq_db = Sequel.connect(adapter: :d1, d1: db)
    rows = seq_db[:posts].order(Sequel.desc(:id)).limit(20).all
    { 'count' => rows.size, 'posts' => rows }.to_json
  end
  post '/posts' do
    content_type 'application/json'
    begin
      payload = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError => e
      status 400
      next({ 'error' => "invalid JSON: #{e.message}" }.to_json)
    end
    title = payload['title'].to_s.strip
    body_text = payload['body'].to_s.strip
    if title.empty?
      status 400
      next({ 'error' => 'title is required' }.to_json)
    end
    # Use Cloudflare::D1Database directly for the insert + readback.
    # D1's execute() accepts `?` placeholders and binds as an Array,
    # matching sqlite3-ruby's idiom (same shape `/d1/users POST`
    # route already relies on).
    row = db.get_first_row(
      'INSERT INTO posts (title, body) VALUES (?, ?) RETURNING id, title, body, created_at',
      [title, body_text]
    )
    status 201
    { 'ok' => true, 'post' => row }.to_json
  end
  get '/test/sequel' do
    content_type 'application/json'
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

    seq_db = Sequel.connect(adapter: :d1, d1: db)

    run.call('adapter_scheme is :d1') { seq_db.adapter_scheme == :d1 }
    run.call('database_type is :sqlite') { seq_db.database_type == :sqlite }
    run.call('SingleConnectionPool in use') { seq_db.pool.class.name == 'Sequel::SingleConnectionPool' }
    run.call('DB[:users].sql emits SELECT * FROM users') {
      seq_db[:users].sql.to_s == 'SELECT * FROM `users`'
    }
    run.call('DB[:users].where(id: 1).sql emits id = 1') {
      seq_db[:users].where(id: 1).sql.to_s == 'SELECT * FROM `users` WHERE (`id` = 1)'
    }
    run.call('DB[:users].order(:id).limit(5) emits ORDER BY + LIMIT') {
      sql = seq_db[:users].order(:id).limit(5).sql.to_s
      sql.include?('ORDER BY `id`') && sql.include?('LIMIT 5')
    }
    run.call('DB[:users].all hits D1 and returns rows') {
      rows = seq_db[:users].all
      rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) && r['id'] && r['name'] }
    }
    run.call('DB[:users].where(id: 1).first.__await__ returns single row') {
      row = seq_db[:users].where(id: 1).first.__await__
      row.is_a?(Hash) && row['id'].to_i == 1
    }

    pass_count = cases.count { |c| c['pass'] }
    { 'phase' => 12, 'total' => cases.size, 'passed' => pass_count,
      'failed' => cases.size - pass_count, 'cases' => cases }.to_json
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
    access_token = JWT.encode(payload, sign_key, alg)

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
      payload, header = JWT.decode(token, verify_key, true, algorithm: alg)
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
    access_token = JWT.encode(payload, sign_key, alg)

    {
      'access_token' => access_token,
      'token_type'   => 'Bearer',
      'expires_in'   => JWT_ACCESS_TTL,
      'alg'          => alg
    }.to_json
  end
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
      e.update('payload-gcm'); ct = e.final; tag = e.auth_tag
      d = OpenSSL::Cipher.new('AES-256-GCM').decrypt; d.key = key; d.iv = iv; d.auth_tag = tag
      d.update(ct); d.final == 'payload-gcm'
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
      ct = ct + e.final
      d = OpenSSL::Cipher.new('AES-256-CTR').decrypt; d.key = key; d.iv = iv
      d.update(ct).__await__ + d.final == plain
    }
    run.call('AES-128-CBC round-trip') {
      key = SecureRandom.random_bytes(16); iv = SecureRandom.random_bytes(16)
      e = OpenSSL::Cipher.new('AES-128-CBC').encrypt; e.key = key; e.iv = iv
      e.update('cbc-test'); ct = e.final
      d = OpenSSL::Cipher.new('AES-128-CBC').decrypt; d.key = key; d.iv = iv
      d.update(ct); d.final == 'cbc-test'
    }
    run.call('RSA RS256 sign/verify') {
      r = OpenSSL::PKey::RSA.new(2048)
      sig = r.sign(OpenSSL::Digest::SHA256.new, 'rs256')
      r.public_key.verify(OpenSSL::Digest::SHA256.new, sig, 'rs256')
    }
    run.call('RSA PS256 sign/verify') {
      r = OpenSSL::PKey::RSA.new(2048)
      sig = r.sign_pss('SHA256', 'ps256', salt_length: :digest, mgf1_hash: 'SHA256')
      r.public_key.verify_pss('SHA256', sig, 'ps256', salt_length: :digest, mgf1_hash: 'SHA256')
    }
    run.call('RSA OAEP encrypt/decrypt') {
      r = OpenSSL::PKey::RSA.new(2048)
      ct = r.public_key.public_encrypt('oaep-payload')
      r.private_decrypt(ct) == 'oaep-payload'
    }
    run.call('ECDSA ES256 (DER) sign/verify') {
      ec = OpenSSL::PKey::EC.generate('prime256v1')
      sig = ec.sign(OpenSSL::Digest::SHA256.new, 'es256')
      sig.bytes[0] == 0x30 && ec.verify(OpenSSL::Digest::SHA256.new, sig, 'es256')
    }
    run.call('ECDSA ES384 sign/verify') {
      ec = OpenSSL::PKey::EC.generate('secp384r1')
      sig = ec.sign(OpenSSL::Digest::SHA384.new, 'es384')
      ec.verify(OpenSSL::Digest::SHA384.new, sig, 'es384')
    }
    run.call('ECDSA ES512 sign/verify') {
      ec = OpenSSL::PKey::EC.generate('secp521r1')
      sig = ec.sign(OpenSSL::Digest::SHA512.new, 'es512')
      ec.verify(OpenSSL::Digest::SHA512.new, sig, 'es512')
    }
    run.call('ECDH P-256 agreement') {
      a = OpenSSL::PKey::EC.generate('prime256v1')
      b = OpenSSL::PKey::EC.generate('prime256v1')
      a.dh_compute_key(b) == b.dh_compute_key(a)
    }
    run.call('Ed25519 sign/verify (EdDSA)') {
      ed = OpenSSL::PKey::Ed25519.generate
      sig = ed.sign(nil, 'eddsa')
      ed.verify(nil, sig, 'eddsa')
    }
    run.call('X25519 key agreement') {
      a = OpenSSL::PKey::X25519.generate
      b = OpenSSL::PKey::X25519.generate
      a.dh_compute_key(b) == b.dh_compute_key(a)
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
      tok = JWT.encode(jwt_payload, jwt_secret, 'HS256')
      dec, = JWT.decode(tok, jwt_secret, true, algorithm: 'HS256')
      dec['sub'] == 'self-test'
    }
    run.call('JWT HS256 tampered signature rejected') {
      tok = JWT.encode(jwt_payload, jwt_secret, 'HS256')
      parts = tok.split('.')
      mid = parts[2].length / 2
      parts[2] = parts[2][0, mid] + (parts[2][mid] == 'A' ? 'B' : 'A') + parts[2][mid + 1, parts[2].length - mid - 1]
      raised = false
      begin
        JWT.decode(parts.join('.'), jwt_secret, true, algorithm: 'HS256')
      rescue JWT::VerificationError
        raised = true
      end
      raised
    }

    rsa = OpenSSL::PKey::RSA.new(2048)
    run.call('JWT RS256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, rsa, 'RS256')
      dec, = JWT.decode(tok, rsa.public_key, true, algorithm: 'RS256')
      dec['sub'] == 'self-test'
    }
    run.call('JWT PS256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, rsa, 'PS256')
      dec, = JWT.decode(tok, rsa.public_key, true, algorithm: 'PS256')
      dec['sub'] == 'self-test'
    }
    run.call('JWT RS256 tampered signature rejected') {
      tok = JWT.encode(jwt_payload, rsa, 'RS256')
      parts = tok.split('.')
      mid = parts[2].length / 2
      parts[2] = parts[2][0, mid] + (parts[2][mid] == 'A' ? 'B' : 'A') + parts[2][mid + 1, parts[2].length - mid - 1]
      raised = false
      begin
        JWT.decode(parts.join('.'), rsa.public_key, true, algorithm: 'RS256')
      rescue JWT::VerificationError
        raised = true
      end
      raised
    }

    ec256 = OpenSSL::PKey::EC.generate('prime256v1')
    run.call('JWT ES256 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ec256, 'ES256')
      dec, = JWT.decode(tok, ec256, true, algorithm: 'ES256')
      dec['sub'] == 'self-test'
    }
    ec384 = OpenSSL::PKey::EC.generate('secp384r1')
    run.call('JWT ES384 encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ec384, 'ES384')
      dec, = JWT.decode(tok, ec384, true, algorithm: 'ES384')
      dec['sub'] == 'self-test'
    }

    ed = OpenSSL::PKey::Ed25519.generate
    run.call('JWT EdDSA encode/decode round-trip') {
      tok = JWT.encode(jwt_payload, ed, 'EdDSA')
      dec, = JWT.decode(tok, ed, true, algorithm: 'EdDSA')
      dec['sub'] == 'self-test'
    }
    run.call('JWT EdDSA tampered signature rejected') {
      tok = JWT.encode(jwt_payload, ed, 'EdDSA')
      parts = tok.split('.')
      mid = parts[2].length / 2
      parts[2] = parts[2][0, mid] + (parts[2][mid] == 'A' ? 'B' : 'A') + parts[2][mid + 1, parts[2].length - mid - 1]
      raised = false
      begin
        JWT.decode(parts.join('.'), ed, true, algorithm: 'EdDSA')
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
    ct  = enc.final
    tag = enc.auth_tag
    dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
    dec.key = key; dec.iv = iv; dec.auth_tag = tag
    dec.update(ct)
    recovered = dec.final

    # 4) RSA sign + verify (Web Crypto subtle async)
    rsa = OpenSSL::PKey::RSA.new(2048)
    msg = 'phase 7 rsa payload'
    sig = rsa.sign(OpenSSL::Digest::SHA256.new, msg)
    rsa_ok = rsa.public_key.verify(OpenSSL::Digest::SHA256.new, sig, msg)

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
    result = App.dispatch_scheduled(event, env['cloudflare.env'], env['cloudflare.ctx'])
    result.merge('cron' => cron, 'registered_crons' => App.scheduled_jobs.map(&:cron)).to_json
  end
  get '/login' do
    @title = 'Login — homurabi'
    @login_error = nil
    @content = erb :login
    erb :layout
  end
  post '/login' do
    username = params['username'].to_s.strip
    return_to = params['return_to'].to_s
    # Reject protocol-relative (`//evil.example`) and anything with
    # whitespace/newlines so the Location: header stays strictly
    # within-site. `\A/(?!/)\S*\z` → starts with single `/`, no `//`
    # prefix, no whitespace.
    return_to = '/chat' unless return_to.match?(%r{\A/(?!/)\S*\z})

    # `:` is the session cookie payload delimiter (`username:exp`
    # → base64url → HMAC). Allowing `:` in the username would
    # truncate it on verification (split(':', 2)), so the
    # displayed/stored user wouldn't match what was entered.
    if username.empty? || username.length > 64 || username.include?(':')
      @title = 'Login — homurabi'
      @login_error = 'username is required (1-64 chars, no colon)'
      @content = erb :login
      next erb :layout
    end

    # mint_session_cookie is sync (HMAC-SHA256 via node:crypto).
    # Keeping the route body sync lets `redirect` work normally.
    token = mint_session_cookie(username)
    response.set_cookie(SESSION_COOKIE_NAME, {
      value: token,
      path: '/',
      httponly: true,
      secure: request.scheme == 'https',
      same_site: :lax,
      max_age: SESSION_COOKIE_TTL
    })
    # 303 See Other — explicitly tells the client to follow up with
    # GET, avoiding any ambiguous POST-replay semantics around 302.
    redirect return_to, 303
  end
  get '/logout' do
    response.delete_cookie(SESSION_COOKIE_NAME, path: '/')
    redirect '/'
  end
  get '/chat' do
    # /chat's body is async (load_chat_history is auto-awaited), so
    # `redirect` (which throws :halt) would surface as
    # `UncaughtThrowError: uncaught throw "halt"` past the async
    # boundary. Set Location on the response (captured into
    # `js_headers` by build_js_response before any await), then
    # return a 2-element `[status, body]` tuple that the JS
    # override in `lib/cloudflare_workers.rb` recognises.
    unless current_session_user
      response['Location'] = "/login?return_to=#{Rack::Utils.escape('/chat')}"
      next [302, '']
    end

    @title = 'homurabi /chat — Workers AI'
    @primary_model  = CHAT_MODELS[:primary]
    @fallback_model = CHAT_MODELS[:fallback]
    @session_id = normalize_session_id(params['session'])
    @history = ai_demos_enabled? ? load_chat_history(@session_id) : []
    @content = erb :chat
    erb :layout
  end
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
    history = load_chat_history(session_id)
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
      )
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
        )
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
    save_chat_history(session_id, new_history)

    {
      'ok'           => true,
      'session'      => session_id,
      'model'        => used_model,
      'used_fallback'=> used_fallback,
      'elapsed_ms'   => elapsed_ms,
      'reply'        => reply_text,
      # Phase 11B follow-up: pre-rendered HTML so the client can
      # `innerHTML = reply_html` to show Markdown formatting (bullet
      # lists, bold, code fences, links). Safe to insert because
      # `HomurabiMarkdown.render` HTML-escapes the input first and
      # restricts link hrefs to http/https/mailto/relative.
      'reply_html'   => markdown_html(reply_text),
      'history_len'  => new_history.size
    }.to_json
  end
  get '/api/chat/messages' do
    content_type 'application/json'
    gate = ai_demos_block_or_nil
    next gate if gate
    auth = chat_verify_token!
    if auth['ok'] != true
      # See the long comment in POST /api/chat/messages for why we
      # return [status, body] instead of using `status N; next body`
      # — Sinatra snapshots response.status before the await resolves,
      # so any later mutation is lost.
      next [auth['status'].to_i, auth['body']]
    end
    session_id = normalize_session_id(params['session'])
    history = load_chat_history(session_id)
    # Include a pre-rendered HTML for each message so the client can
    # show Markdown-formatted history without re-running a JS parser.
    history_enriched = history.map do |m|
      role = m['role'].to_s
      content = m['content'].to_s
      item = { 'role' => role, 'content' => content }
      # Only assistant replies are converted — user messages are
      # authored text and stay as-is to preserve the exact payload.
      item['content_html'] = markdown_html(content) if role == 'assistant'
      item
    end
    {
      'session' => session_id,
      'history' => history_enriched
    }.to_json
  end
  delete '/api/chat/messages' do
    content_type 'application/json'
    gate = ai_demos_block_or_nil
    next gate if gate
    auth = chat_verify_token!
    if auth['ok'] != true
      # See the long comment in POST /api/chat/messages for why we
      # return [status, body] instead of using `status N; next body`
      # — Sinatra snapshots response.status before the await resolves,
      # so any later mutation is lost.
      next [auth['status'].to_i, auth['body']]
    end
    session_id = normalize_session_id(params['session'])
    clear_chat_history(session_id)
    { 'ok' => true, 'session' => session_id, 'cleared' => true }.to_json
  end
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
    )
    {
      'model'    => model,
      'class'    => out.class.to_s,
      'is_hash'  => out.is_a?(Hash),
      'keys'     => out.is_a?(Hash) ? out.keys : nil,
      'extracted'=> App.extract_ai_text(out),
      'raw'      => out
    }.to_json
  end
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
        )
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

    cases << test_one.call(primary,  "primary model #{primary} responds")
    cases << test_one.call(fallback, "fallback model #{fallback} responds")

    passed = cases.count { |c| c['pass'] }
    failed = cases.size - passed
    {
      'passed' => passed,
      'failed' => failed,
      'total'  => cases.size,
      'cases'  => cases
    }.to_json
  end
  get '/demo/do/ws' do
    unless binding_demos_enabled?
      status 404
      content_type 'application/json'
      next({ 'error' => 'binding demos disabled' }.to_json)
    end
    # Copilot review PR #9 (third pass): Workers only accepts a
    # `Response` with a `.webSocket` property from a handler that
    # was invoked by a real WebSocket-upgrade request. If a plain
    # `curl` (no Upgrade header) hits this route, forwarding to the
    # DO stub causes the runtime to throw ("Response with webSocket
    # requires a WebSocket request"), surfacing as a confusing 500.
    # Reject non-upgrade requests up-front with a 426 so clients
    # get an intentional, documented response.
    upgrade = (request.env['HTTP_UPGRADE'] || '').to_s.downcase
    unless upgrade == 'websocket'
      status 426
      content_type 'application/json'
      next({
        'error' => 'Upgrade Required',
        'detail' => 'GET /demo/do/ws must be called with `Upgrade: websocket`; use a WebSocket client.'
      }.to_json)
    end
    ns = do_counter
    if ns.nil?
      status 503
      content_type 'application/json'
      next({ 'error' => 'COUNTER binding not bound' }.to_json)
    end
    name = (params['name'] || 'ws-demo').to_s
    stub = ns.get_by_name(name)
    # Forward a WebSocket-upgrade request to the DO stub. The stub's
    # fetch() returns a 101 Response with `.webSocket` attached;
    # Cloudflare::RawResponse signals to build_js_response that the
    # JS Response must be passed through untouched (normal bodies
    # lose the WebSocket property when reconstructed).
    js_resp = stub.fetch_raw(
      "https://homurabi-do.internal/ws/#{name}",
      method: 'GET',
      headers: { 'upgrade' => 'websocket' }
    )
    Cloudflare::RawResponse.new(js_resp)
  end
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
    res = stub.fetch(url, method: 'POST')
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
    q.send(body)
    status 202
    { 'enqueued' => true, 'queue' => 'homurabi-jobs', 'payload' => body }.to_json
  end
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
    cached = named.match(cache_key).__await__
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
      }).__await__
      payload.merge(
        'cache' => state,
        'elapsed_ms' => ((Time.now.to_f - started) * 1000).round
      ).to_json
    end
  end
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
    summary = Cloudflare::QueueConsumer.dispatch_js(js_batch, env['cloudflare.env'], env['cloudflare.ctx'])
    summary.merge('injected' => messages.size).to_json
  end
  get '/demo/queue/dlq-status' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled' }.to_json)
    end
    if kv.nil?
      status 503
      next({ 'error' => 'KV not bound — cannot read DLQ state' }.to_json)
    end
    limit = (params['limit'] || '10').to_i
    recent = []
    i = 0
    while i < limit
      raw = kv.get("queue:dlq:#{i}").__await__
      break if raw.nil? || raw.empty?
      begin
        recent << JSON.parse(raw)
      rescue JSON::ParserError
        recent << { 'raw' => raw }
      end
      i += 1
    end
    {
      'queue'   => 'homurabi-jobs-dlq',
      'count'   => recent.size,
      'recent'  => recent
    }.to_json
  end
  post '/demo/queue/force-dlq' do
    content_type 'application/json'
    unless binding_demos_enabled?
      status 404
      next({ 'error' => 'binding demos disabled' }.to_json)
    end
    q = jobs_queue
    if q.nil?
      status 503
      next({ 'error' => 'Queue binding JOBS_QUEUE not bound' }.to_json)
    end
    payload = { 'fail' => true, 'reason' => 'force-dlq demo', 'ts' => Time.now.to_i }
    q.send(payload)
    status 202
    { 'enqueued' => true, 'payload' => payload, 'note' => 'main consumer will retry up to max_retries; then the runtime forwards the message to homurabi-jobs-dlq' }.to_json
  end
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
        stub.fetch("#{base}/reset", method: 'POST')
        r1 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').body)
        r2 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').body)
        peek = JSON.parse(stub.fetch("#{base}/peek").body)
        do_case['pass'] = r1['count'] == 1 && r2['count'] == 2 && peek['count'] == 2
        do_case['detail'] = { 'r1' => r1, 'r2' => r2, 'peek' => peek }
        stub.fetch("#{base}/reset", method: 'POST')
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
        q.send({ 'selftest' => true, 'ts' => Time.now.to_i, 'nonce' => SecureRandom.hex(4) })
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
    res = client.get('/', { 'format' => 'json' }).__await__
    {
      'demo'        => 'Faraday.new(url:) { request :json; response :json }',
      'status'      => res.status,
      'success'     => res.success?,
      'reason'      => res.reason_phrase,
      'body'        => res.body,  # parsed Hash thanks to :json middleware
      'headers_ct'  => res.headers['content-type']
    }.to_json
  end
  post '/api/upload' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    # pull params BEFORE the first await — Sinatra clears @params when
    # it starts a Promise-returning route (same ceremony as /d1/users).
    file_param = params['file']
    note_param = params['note'].to_s
    unless file_param.is_a?(::Cloudflare::UploadedFile)
      status 400
      next({ 'error' => 'missing "file" multipart part' }.to_json)
    end

    # Only accept images — this is the /phase11a/upload demo's purpose.
    # Rejecting non-image content types here stops the gallery ever
    # accumulating bytes it can't render (the historical curl-smoke
    # `.bin` payloads came in before this check existed).
    ct = file_param.content_type.to_s
    unless ct.start_with?('image/')
      status 415  # Unsupported Media Type
      next({
        'error'         => 'only image/* content types are accepted',
        'received_type' => ct.empty? ? '(missing)' : ct,
        'filename'      => file_param.filename
      }.to_json)
    end

    if bucket.nil?
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end

    # Pick a random key under a phase11a/ prefix so we don't collide
    # with the existing /r2/:key demos.
    key = "phase11a/uploads/#{SecureRandom.hex(8)}-#{file_param.filename}"
    u8  = file_param.to_uint8_array
    bucket.put(key, u8, file_param.content_type).__await__

    status 201
    {
      'stored'       => true,
      'key'          => key,
      'filename'     => file_param.filename,
      'content_type' => file_param.content_type,
      'size'         => file_param.size,
      'note'         => note_param,
      'url'          => "/r2/#{key}"  # hit via GET /images/:key for binary
    }.to_json
  end
  get '/phase11a/upload' do
    @title = 'Phase 11A — image upload demo'
    unless foundations_demos_enabled?
      status 404
      @content = '<p>foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1).</p>'
      next erb :layout
    end
    @images = []
    @non_image_count = 0
    if bucket
      rows = bucket.list(prefix: 'phase11a/uploads/', limit: 50)
      # Partition into image rows (→ gallery) and non-image rows
      # (legacy curl-smoke binary payloads that predate the MIME
      # guard below). The gallery only renders real images so we
      # never draw an `<img src=…>` pointing at bytes the browser
      # can't decode.
      rows.each do |row|
        ct = row['content_type'].to_s
        if ct.start_with?('image/')
          filename = row['key'].to_s.split('/').last.to_s
          display_name = filename.sub(/\A[0-9a-f]+-/, '')
          @images << {
            'key'          => row['key'],
            'download_url' => "/phase11a/download/#{row['key']}",
            'filename'     => display_name,
            'content_type' => ct,
            'size'         => row['size'],
            'note'         => nil  # R2 doesn't preserve our custom note
          }
        else
          @non_image_count += 1
        end
      end
    end
    @content = erb :phase11a_upload
    erb :layout
  end
  post '/phase11a/cleanup' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    if bucket.nil?
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end
    rows = bucket.list(prefix: 'phase11a/uploads/', limit: 1000)
    deleted_keys = []
    rows.each do |row|
      ct = row['content_type'].to_s
      next if ct.start_with?('image/')
      k = row['key'].to_s
      # Double-check we're still in our prefix before deleting.
      next unless k.start_with?('phase11a/uploads/')
      bucket.delete(k).__await__
      deleted_keys << k
    end
    { 'deleted_count' => deleted_keys.length, 'deleted' => deleted_keys }.to_json
  end
  delete '/phase11a/uploads/*' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    if bucket.nil?
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end
    key = params['splat'].is_a?(Array) ? params['splat'].join('/') : params['splat'].to_s
    full = "phase11a/uploads/#{key}"
    # Safety: only ever delete under our own prefix. The splat route
    # already enforces this prefix structurally, but a belt-and-braces
    # startswith check protects against future routing changes.
    unless full.start_with?('phase11a/uploads/')
      status 400
      next({ 'error' => 'refusing to delete outside phase11a/uploads/', 'key' => full }.to_json)
    end
    bucket.delete(full).__await__
    { 'deleted' => true, 'key' => full }.to_json
  end
  get '/phase11a/download/*' do
    unless foundations_demos_enabled?
      content_type 'application/json'
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    if bucket.nil?
      content_type 'application/json'
      status 503
      next({ 'error' => 'R2 binding not configured' }.to_json)
    end
    key = params['splat'].is_a?(Array) ? params['splat'].join('/') : params['splat'].to_s
    obj = bucket.get_binary(key)
    if obj.nil?
      content_type 'application/json'
      status 404
      next({ 'error' => 'not found', 'key' => key }.to_json)
    else
      obj  # BinaryBody — build_js_response streams raw bytes to client
    end
  end
  get '/demo/stream' do
    unless foundations_demos_enabled?
      content_type 'application/json'
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    stream do |out|
      i = 0
      while i < 3
        out << "chunk #{i} @ #{Time.now.to_i}\n"
        out.sleep(0.5)
        i += 1
      end
      out << "done\n"
    end
  end
  get '/demo/sse' do
    unless foundations_demos_enabled?
      content_type 'application/json'
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    sse do |out|
      # Manual `while` instead of `Integer#times` because Opal compiles
      # `.each` / `.times` iterators as synchronous JS `for` loops —
      # the async block returns a Promise per iteration that the loop
      # does NOT await, so all five ticks would flush as a single
      # batch (CPU ~8ms total instead of the intended ~5s). A bare
      # `while` inside a `# await: true` block compiles to a real
      # async JS loop that honours `await` between iterations.
      i = 0
      while i < 5
        out.event(
          { 'tick' => i, 'ts' => Time.now.to_i, 'note' => 'phase11a-sse' }.to_json,
          event: 'heartbeat',
          id: i.to_s
        )
        out.sleep(1)
        i += 1
      end
      out.event('done', event: 'close')
    end
  end
  get '/test/foundations' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
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

    # Faraday GET with :json middleware, hitting the only stable public
    # API we're willing to depend on in a self-test (ipify). httpbin.org
    # was tried here earlier and blew up the Workers isolate with
    # "Reached heap limit" — the body comes back huge and JSON-parsing
    # it inside Opal is not free.
    run.call('Faraday GET with :json middleware round-trips') {
      c = Faraday.new(url: 'https://api.ipify.org') do |conn|
        conn.request :json
        conn.response :json
      end
      res = c.get('/', { 'format' => 'json' }).__await__
      res.success? && res.body.is_a?(Hash) && res.body['ip']
    }

    # :raise_error + Faraday.new on an existing URL that returns non-2xx.
    # We don't hit httpbin (too heavy), so use an obviously-404 path on
    # ipify which always responds 404 with a short body.
    run.call('Faraday raise_error raises ResourceNotFound on 404') {
      c = Faraday.new(url: 'https://api.ipify.org') do |conn|
        conn.response :raise_error
      end
      raised = nil
      begin
        c.get('/this-path-does-not-exist-11a').__await__
      rescue Faraday::ResourceNotFound => e
        raised = e
      end
      raised && raised.response_status == 404
    }

    # Offline test — the :json request middleware must encode a Hash
    # body as JSON without hitting the network. We inspect the Env
    # directly instead of a live round-trip.
    run.call('Faraday :json middleware encodes Hash body (offline)') {
      env = Faraday::Env.new(method: :post, url: 'https://example.com/x')
      env.body = { 'name' => 'homurabi', 'phase' => 11 }
      Faraday::Middleware::JSON.new.on_request(env)
      env.body == '{"name":"homurabi","phase":11}' &&
        env.request_headers['content-type'] == 'application/json'
    }

    run.call('Multipart parser extracts file + text field') {
      boundary = '----phase11atest'
      body = ''
      body += "--#{boundary}\r\n"
      body += "Content-Disposition: form-data; name=\"note\"\r\n\r\n"
      body += "hello-11a\r\n"
      body += "--#{boundary}\r\n"
      body += "Content-Disposition: form-data; name=\"file\"; filename=\"t.bin\"\r\n"
      body += "Content-Type: application/octet-stream\r\n\r\n"
      body += "\x00\x01\x02payload"
      body += "\r\n--#{boundary}--\r\n"
      parsed = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{boundary}")
      parsed['note'] == 'hello-11a' &&
        parsed['file'].is_a?(Cloudflare::UploadedFile) &&
        parsed['file'].filename == 't.bin' &&
        parsed['file'].size == "\x00\x01\x02payload".length
    }

    run.call('UploadedFile#to_uint8_array preserves raw bytes') {
      # Build the 4-byte input with `.chr` — a Ruby source literal like
      # "\xDE\xAD\xBE\xEF" would be UTF-8-decoded by Opal at compile
      # time and the high bytes would collapse to U+FFFD before this
      # case ran (same workaround used in test/multipart_smoke.rb).
      bytes = 0xDE.chr + 0xAD.chr + 0xBE.chr + 0xEF.chr
      u = Cloudflare::UploadedFile.new(name: 'f', filename: 'a.bin', content_type: 'application/octet-stream', bytes_binstr: bytes)
      arr = u.to_uint8_array
      `#{arr}.length === 4 && #{arr}[0] === 0xDE && #{arr}[1] === 0xAD && #{arr}[2] === 0xBE && #{arr}[3] === 0xEF`
    }

    run.call('SSEStream frames data correctly') {
      # Use a TransformStream and inspect what Ruby writes to the writer.
      ts = `new TransformStream()`
      writer = `#{ts}.writable.getWriter()`
      out = Cloudflare::SSEOut.new(writer)
      out.event('hello', event: 'greet', id: '1')
      out.write("data: raw\n\n")
      out.close
      # Drain via a JS IIFE so Opal doesn't compile this into a
      # `loop do … __await__ … break` — which allocates a Promise per
      # iteration and blows up the workerd isolate under heavy load
      # (observed: V8 OOM after ~60s on /test/foundations).
      readable = `#{ts}.readable`
      decoded = `(async function(r){ var rd=r.getReader(); var d=new TextDecoder(); var out=''; while(true){ var c=await rd.read(); if(c.done) return out; out += d.decode(c.value); } })(#{readable})`.__await__
      decoded.include?('event: greet') &&
        decoded.include?('id: 1') &&
        decoded.include?('data: hello') &&
        decoded.include?('data: raw')
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
  # Phase 16 — self-hosted docs (Cloudflare-style /docs/*)
  # Note: Mustermann on Opal rejects regex anchors (^ / $); use two paths for /docs and /docs/.
  docs_index_route = lambda do
    @title = 'ドキュメント — homurabi'
    @docs_page = 'index'
    @docs_section = :getting_started
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['概要', nil]
    ]
    @docs_toc = [
      %w[hero このサイトについて],
      %w[gems 3つの gem],
      %w[next 次のステップ]
    ]
    @docs_inner = erb :docs_index
    erb :layout_docs
  end
  get '/docs', &docs_index_route
  get '/docs/quick-start' do
    @title = 'クイックスタート — homurabi Docs'
    @docs_page = 'quick-start'
    @docs_section = :getting_started
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['Getting Started', '/docs'],
      ['Quick Start', nil]
    ]
    @docs_toc = [
      %w[prereq 前提],
      %w[scaffold 新規プロジェクト],
      %w[run-local ローカルで動かす],
      %w[deploy デプロイ],
      %w[limits 現在の制限]
    ]
    @docs_inner = erb :docs_quick_start
    erb :layout_docs
  end
  get '/docs/migration' do
    @title = '移行ガイド — homurabi Docs'
    @docs_page = 'migration'
    @docs_section = :guides
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['Migration Guide', nil]
    ]
    @docs_toc = [
      %w[scope 対象と非対象],
      %w[steps 6 ステップ],
      %w[gotchas よくあるハマり],
      %w[blockers 移行が難しい例]
    ]
    @docs_inner = erb :docs_migration
    erb :layout_docs
  end
  get '/docs/sinatra' do
    @title = 'sinatra-cloudflare-workers — homurabi Docs'
    @docs_page = 'sinatra'
    @docs_section = :reference
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['API Reference', '/docs/runtime'],
      ['sinatra-cloudflare-workers', nil]
    ]
    @docs_toc = [
      %w[overview 概要],
      %w[register 登録と require],
      %w[erb ERB プリコンパイル],
      %w[jwt JWT],
      %w[scheduled Cron],
      %w[queue Queues],
      %w[matrix できること / できないこと]
    ]
    @docs_inner = erb :docs_sinatra
    erb :layout_docs
  end
  get '/docs/sequel-d1' do
    @title = 'sequel-d1 — homurabi Docs'
    @docs_page = 'sequel-d1'
    @docs_section = :reference
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['API Reference', '/docs/runtime'],
      ['sequel-d1', nil]
    ]
    @docs_toc = [
      %w[connect 接続],
      %w[migrate マイグレーション],
      %w[opal Opal ビルドパス],
      %w[matrix できること / できないこと]
    ]
    @docs_inner = erb :docs_sequel_d1
    erb :layout_docs
  end
  get '/docs/runtime' do
    @title = 'cloudflare-workers-runtime — homurabi Docs'
    @docs_page = 'runtime'
    @docs_section = :reference
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['API Reference', '/docs/runtime'],
      ['cloudflare-workers-runtime', nil]
    ]
    @docs_toc = [
      %w[role 役割],
      %w[build ビルド CLI],
      %w[entrypoint worker.entrypoint.mjs],
      %w[matrix できること / できないこと]
    ]
    @docs_inner = erb :docs_runtime
    erb :layout_docs
  end
  get '/docs/architecture' do
    @title = 'アーキテクチャ — homurabi Docs'
    @docs_page = 'architecture'
    @docs_section = :architecture
    @docs_breadcrumb = [
      ['Docs', '/docs'],
      ['Architecture', nil]
    ]
    @docs_toc = [
      %w[self-host セルフホスト],
      %w[gems 3 gem の関係],
      %w[pipeline ビルドパイプライン],
      %w[history Phase 15 の整理],
      %w[diagram 依存関係 (Mermaid)]
    ]
    @docs_inner = erb :docs_architecture
    erb :layout_docs
  end
