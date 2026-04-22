# frozen_string_literal: true
# Route fragment 25 — test /test/crypto
get '/test/crypto' do
  content_type 'application/json'
  unless crypto_demos_enabled?
    status 404
    next { 'error' => 'crypto demos disabled (set HOMURA_ENABLE_CRYPTO_DEMOS=1 in wrangler vars)' }.to_json
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
      ct = ct + e.update(plain[i, 13]); i += 13
    end
    ct = ct + e.final
    d = OpenSSL::Cipher.new('AES-256-CTR').decrypt; d.key = key; d.iv = iv
    d.update(ct) + d.final == plain
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
