# await: true
# frozen_string_literal: true
# Route fragment 26 — demo /demo/crypto
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
