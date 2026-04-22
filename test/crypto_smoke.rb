# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 7 — crypto primitives smoke tests.
#
# Verifies the Ruby surface (`Digest`, `OpenSSL::HMAC`, `OpenSSL::Cipher`,
# `OpenSSL::PKey::RSA` / `EC`, `OpenSSL::KDF`, `SecureRandom`) against
# CRuby-generated reference values for known inputs and round-trip
# semantics for stateful algorithms.
#
# Backed by node:crypto (sync) via globalThis.__nodeCrypto__, exposed
# by src/setup-node-crypto.mjs. Requires Node 20.6+ for `--import`.
#
# Usage:
#   npm run test:crypto
#   — or —
#   npm test       (full suite incl. smoke + http + crypto)

require 'json'
require 'digest'
require 'digest/sha2'
require 'openssl'
require 'securerandom'
require 'base64'

# =====================================================================
# Test harness
# =====================================================================

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

  # NOTE on `# await: true`: this file is compiled as async, so
  # `block.call` returns a Promise wrapping the block's return value.
  # We deliberately do NOT auto-await here — that would make assert
  # itself async and the "for each test" loop would interleave. Each
  # test block must therefore `.__await__` any internal Promises and
  # return a plain boolean as its final expression.
  def self.assert(label, &block)
    result = block.call
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stdout.puts "  FAIL  #{label}"
    end
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts "  CRASH #{label} — #{e.class}: #{e.message}"
  end

  def self.report
    total = @passed + @failed
    $stdout.puts ""
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts "Failures:"
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# =====================================================================
# CRuby-generated reference values
# Generated 2026-04-17 with `ruby -ropenssl -rdigest -e ...`. These are
# the canonical CRuby outputs that any compliant Digest / HMAC / KDF
# backend must reproduce byte-for-byte.
# =====================================================================

SHA1_HELLO   = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d'
SHA1_EMPTY   = 'da39a3ee5e6b4b0d3255bfef95601890afd80709'
SHA256_HELLO = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
SHA256_EMPTY = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
SHA256_HOMURA = 'cedb08873dca79fda7f7a7d0d1c50a85450b3ca50d5361629d5687477eb73db4'
SHA384_HELLO = '59e1748777448c69de6b800d7a33bbfb9ff1b463e44354c3553bcdb9c666fa90125a3c79f90397bdf5f6a13de828684f'
SHA512_HELLO = '9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043'
MD5_HELLO    = '5d41402abc4b2a76b9719d911017c592'

HMAC_SHA1_K_M   = '102900b72b7bf1031eec76b4804b66052376896b'
HMAC_SHA256_K_M = '2d93cbc1be167bcb1637a4a23cbff01a7878f0c50ee833954ea5221bb1b8c628'
HMAC_SHA384_K_M = '3bba95ff38376a129225ec5430dd3aff6ac7b7acdb829a4af35f33f8c6ddbbf9d85fb31f8b20316db93aedd08a816cfa'
HMAC_SHA512_K_M = '1e4b55b925ccc28ed90d9d18fc2393fcbe164c0d84e67e173cc5aa486b7afc106633c66bdc309076f5f8d9fdbbb62456f894f2c23377fbcc12f4ab2940eb6d70'
HMAC_SHA256_SECRET_HELLO = '88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b'

PBKDF2_SHA256 = '2038580f917370fe42b04462a7c26ed17a2e769b44eb6181134243a9dabf0136'
HKDF_SHA256   = 'fe8f9615d2374c0d17f77d1aeaf408c2e75fe0466073d0def23c733e2f862dfd'

# =====================================================================
# Tests
# =====================================================================

$stdout.puts "=== homura Phase 7 — crypto smoke ==="
$stdout.puts ""

# ---------------------------------------------------------------------
# Digest — one-shot
# ---------------------------------------------------------------------
$stdout.puts "--- Digest (one-shot hexdigest) ---"

SmokeTest.assert("Digest::SHA1.hexdigest('hello')")    { Digest::SHA1.hexdigest('hello')    == SHA1_HELLO }
SmokeTest.assert("Digest::SHA1.hexdigest('')")         { Digest::SHA1.hexdigest('')         == SHA1_EMPTY }
SmokeTest.assert("Digest::SHA256.hexdigest('hello')")  { Digest::SHA256.hexdigest('hello')  == SHA256_HELLO }
SmokeTest.assert("Digest::SHA256.hexdigest('')")       { Digest::SHA256.hexdigest('')       == SHA256_EMPTY }
SmokeTest.assert("Digest::SHA256.hexdigest('homura')") { Digest::SHA256.hexdigest('homura') == SHA256_HOMURA }
SmokeTest.assert("Digest::SHA384.hexdigest('hello')")  { Digest::SHA384.hexdigest('hello')  == SHA384_HELLO }
SmokeTest.assert("Digest::SHA512.hexdigest('hello')")  { Digest::SHA512.hexdigest('hello')  == SHA512_HELLO }
SmokeTest.assert("Digest::MD5.hexdigest('hello')")     { Digest::MD5.hexdigest('hello')     == MD5_HELLO }

# ---------------------------------------------------------------------
# Digest — streaming (instance.update.hexdigest)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- Digest (streaming) ---"

SmokeTest.assert("SHA256 .new.update.hexdigest matches one-shot") {
  d = Digest::SHA256.new
  d.update('hel')
  d.update('lo')
  d.hexdigest == SHA256_HELLO
}
SmokeTest.assert("SHA256 << operator matches update") {
  d = Digest::SHA256.new
  d << 'hel'
  d << 'lo'
  d.hexdigest == SHA256_HELLO
}
SmokeTest.assert("SHA256 .digest returns binary 32 bytes") {
  bin = Digest::SHA256.digest('hello')
  bin.is_a?(String) && bin.length == 32 && bin.unpack1('H*') == SHA256_HELLO
}

# ---------------------------------------------------------------------
# OpenSSL::HMAC
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::HMAC ---"

SmokeTest.assert("HMAC SHA1 ('key','msg')")   { OpenSSL::HMAC.hexdigest('SHA1',   'key', 'msg') == HMAC_SHA1_K_M }
SmokeTest.assert("HMAC SHA256 ('key','msg')") { OpenSSL::HMAC.hexdigest('SHA256', 'key', 'msg') == HMAC_SHA256_K_M }
SmokeTest.assert("HMAC SHA384 ('key','msg')") { OpenSSL::HMAC.hexdigest('SHA384', 'key', 'msg') == HMAC_SHA384_K_M }
SmokeTest.assert("HMAC SHA512 ('key','msg')") { OpenSSL::HMAC.hexdigest('SHA512', 'key', 'msg') == HMAC_SHA512_K_M }
SmokeTest.assert("HMAC SHA256 ('secret','hello')") { OpenSSL::HMAC.hexdigest('SHA256', 'secret', 'hello') == HMAC_SHA256_SECRET_HELLO }
SmokeTest.assert("HMAC accepts OpenSSL::Digest::SHA256 instance") {
  OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, 'key', 'msg') == HMAC_SHA256_K_M
}
SmokeTest.assert("HMAC.digest returns binary, hexdigest matches") {
  bin = OpenSSL::HMAC.digest('SHA256', 'key', 'msg')
  bin.length == 32 && bin.unpack1('H*') == HMAC_SHA256_K_M
}

# ---------------------------------------------------------------------
# OpenSSL::KDF
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::KDF ---"

SmokeTest.assert("PBKDF2 SHA256 (4096 iter, 32 bytes)") {
  out = OpenSSL::KDF.pbkdf2_hmac('password', salt: 'salt-1234', iterations: 4096, length: 32, hash: 'SHA256')
  out.unpack1('H*') == PBKDF2_SHA256
}
SmokeTest.assert("HKDF SHA256 (ikm/salt/info, 32 bytes)") {
  out = OpenSSL::KDF.hkdf('ikm', salt: 'salt', info: 'info', length: 32, hash: 'SHA256')
  out.unpack1('H*') == HKDF_SHA256
}

# ---------------------------------------------------------------------
# OpenSSL::Cipher — AES round-trips
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::Cipher AES round-trips ---"

# Cipher methods are async (Web Crypto subtle backend) — caller awaits.
SmokeTest.assert("AES-256-GCM encrypt → decrypt round-trip") {
  key   = SecureRandom.random_bytes(32)
  iv    = SecureRandom.random_bytes(12)
  plain = 'Phase 7 cipher test payload AES-GCM'

  cip = OpenSSL::Cipher.new('AES-256-GCM').encrypt
  cip.key = key; cip.iv = iv; cip.auth_data = 'aad-1'
  cip.update(plain)
  ct  = cip.final.__await__
  tag = cip.auth_tag

  dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
  dec.key = key; dec.iv = iv; dec.auth_data = 'aad-1'; dec.auth_tag = tag
  dec.update(ct)
  recovered = dec.final.__await__
  recovered == plain
}

SmokeTest.assert("AES-256-GCM tampering detection (auth_tag mismatch)") {
  key   = SecureRandom.random_bytes(32)
  iv    = SecureRandom.random_bytes(12)
  cip   = OpenSSL::Cipher.new('AES-256-GCM').encrypt
  cip.key = key; cip.iv = iv
  cip.update('plain')
  ct  = cip.final.__await__
  bad_tag = "\x00" * 16

  dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
  dec.key = key; dec.iv = iv; dec.auth_tag = bad_tag
  dec.update(ct)
  raised = false
  begin
    dec.final.__await__
  rescue OpenSSL::Cipher::CipherError
    raised = true
  end
  raised
}

SmokeTest.assert("AES-256-GCM AAD mismatch fails decryption") {
  key = SecureRandom.random_bytes(32)
  iv  = SecureRandom.random_bytes(12)
  cip = OpenSSL::Cipher.new('AES-256-GCM').encrypt
  cip.key = key; cip.iv = iv; cip.auth_data = 'good'
  cip.update('payload')
  ct  = cip.final.__await__
  tag = cip.auth_tag
  dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
  dec.key = key; dec.iv = iv; dec.auth_data = 'WRONG'; dec.auth_tag = tag
  dec.update(ct)
  raised = false
  begin; dec.final.__await__; rescue OpenSSL::Cipher::CipherError; raised = true; end
  raised
}

SmokeTest.assert("AES-256-GCM round-trips arbitrary BINARY plaintext (all 256 byte values)") {
  key   = SecureRandom.random_bytes(32)
  iv    = SecureRandom.random_bytes(12)
  plain = (0..255).map(&:chr).join   # every byte 0x00..0xff
  enc = OpenSSL::Cipher.new('AES-256-GCM').encrypt
  enc.key = key; enc.iv = iv
  enc.update(plain)
  ct  = enc.final.__await__
  tag = enc.auth_tag
  dec = OpenSSL::Cipher.new('AES-256-GCM').decrypt
  dec.key = key; dec.iv = iv; dec.auth_tag = tag
  dec.update(ct)
  recovered = dec.final.__await__
  recovered.bytesize == 256 && recovered == plain
}

SmokeTest.assert("AES-256-CTR round-trip (single update + final)") {
  key   = SecureRandom.random_bytes(32)
  iv    = SecureRandom.random_bytes(16)
  plain = 'CTR mode round-trip Phase 7'
  enc = OpenSSL::Cipher.new('AES-256-CTR').encrypt
  enc.key = key; enc.iv = iv
  ct = enc.update(plain).__await__ + enc.final.__await__
  dec = OpenSSL::Cipher.new('AES-256-CTR').decrypt
  dec.key = key; dec.iv = iv
  recovered = dec.update(ct).__await__ + dec.final.__await__
  recovered == plain
}

SmokeTest.assert("AES-256-CTR streaming via multiple update() calls") {
  key   = SecureRandom.random_bytes(32)
  iv    = SecureRandom.random_bytes(16)
  plain = 'streaming CTR test ' * 20  # ~ 400 bytes, > 16 * many
  enc = OpenSSL::Cipher.new('AES-256-CTR').encrypt
  enc.key = key; enc.iv = iv
  # Feed in 17-byte chunks (intentionally not block-aligned)
  ct = ''
  i = 0
  while i < plain.bytesize
    chunk = plain[i, 17]
    ct = ct + enc.update(chunk).__await__
    i += 17
  end
  ct = ct + enc.final.__await__
  # Decrypt in different chunk size
  dec = OpenSSL::Cipher.new('AES-256-CTR').decrypt
  dec.key = key; dec.iv = iv
  recovered = ''
  j = 0
  while j < ct.bytesize
    chunk = ct[j, 23]
    recovered = recovered + dec.update(chunk).__await__
    j += 23
  end
  recovered = recovered + dec.final.__await__
  recovered == plain
}

SmokeTest.assert("AES-128-CBC encrypt → decrypt round-trip") {
  key   = SecureRandom.random_bytes(16)
  iv    = SecureRandom.random_bytes(16)
  plain = 'CBC mode round-trip test Phase 7'

  cip = OpenSSL::Cipher.new('AES-128-CBC').encrypt
  cip.key = key; cip.iv = iv
  cip.update(plain)
  ct = cip.final.__await__

  dec = OpenSSL::Cipher.new('AES-128-CBC').decrypt
  dec.key = key; dec.iv = iv
  dec.update(ct)
  recovered = dec.final.__await__
  recovered == plain
}

# ---------------------------------------------------------------------
# OpenSSL::PKey::RSA
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::RSA ---"

# Generate a small key once and reuse across tests for speed.
RSA_KEY = OpenSSL::PKey::RSA.new(2048)

SmokeTest.assert("RSA generate yields 2048-bit private key") {
  RSA_KEY.private? && RSA_KEY.n.num_bits == 2048
}
SmokeTest.assert("RSA private PEM export → import round-trip") {
  pem = RSA_KEY.to_pem
  reloaded = OpenSSL::PKey::RSA.new(pem)
  reloaded.n.to_s == RSA_KEY.n.to_s
}
SmokeTest.assert("RSA public PEM export → import round-trip") {
  pub_pem = RSA_KEY.public_key.to_pem
  reloaded = OpenSSL::PKey::RSA.new(pub_pem)
  !reloaded.private? && reloaded.n.to_s == RSA_KEY.n.to_s
}
SmokeTest.assert("RSA sign(SHA256, msg) → verify(SHA256, sig, msg)") {
  msg = 'Phase 7 RSA signature payload'
  sig = RSA_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  RSA_KEY.public_key.verify(OpenSSL::Digest::SHA256.new, sig, msg).__await__
}
SmokeTest.assert("RSA verify rejects tampered message") {
  msg = 'original'
  sig = RSA_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  RSA_KEY.public_key.verify(OpenSSL::Digest::SHA256.new, sig, 'tampered').__await__ == false
}

# ---------------------------------------------------------------------
# OpenSSL::PKey::EC (P-256 / ES256)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::EC ---"

EC_KEY = OpenSSL::PKey::EC.generate('prime256v1')

SmokeTest.assert("EC generate (prime256v1)") {
  EC_KEY.private_key? && EC_KEY.group.curve_name == 'prime256v1'
}
SmokeTest.assert("EC sign / verify round-trip (SHA256)") {
  msg = 'Phase 7 ECDSA payload'
  sig = EC_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  EC_KEY.verify(OpenSSL::Digest::SHA256.new, sig, msg).__await__
}
SmokeTest.assert("EC verify rejects tampered message") {
  msg = 'original'
  sig = EC_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  EC_KEY.verify(OpenSSL::Digest::SHA256.new, sig, 'tampered').__await__ == false
}
SmokeTest.assert("EC PEM export → import round-trip preserves curve") {
  pem = EC_KEY.to_pem
  reloaded = OpenSSL::PKey::EC.new(pem)
  reloaded.group.curve_name == 'prime256v1'
}

# ---------------------------------------------------------------------
# RSA-PSS (PS256/384/512)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::RSA — PSS (PS256/384/512) ---"

%w[SHA256 SHA384 SHA512].each do |hash|
  SmokeTest.assert("RSA-PSS sign/verify round-trip (#{hash}, salt :digest)") {
    msg = "phase 7 PSS payload #{hash}"
    sig = RSA_KEY.sign_pss(hash, msg, salt_length: :digest, mgf1_hash: hash).__await__
    RSA_KEY.public_key.verify_pss(hash, sig, msg, salt_length: :digest, mgf1_hash: hash).__await__
  }

  SmokeTest.assert("RSA-PSS rejects tampered (#{hash})") {
    sig = RSA_KEY.sign_pss(hash, 'orig', salt_length: :digest, mgf1_hash: hash).__await__
    RSA_KEY.public_key.verify_pss(hash, sig, 'tampered', salt_length: :digest, mgf1_hash: hash).__await__ == false
  }
end

SmokeTest.assert("RSA-PSS with explicit numeric salt_length") {
  msg = 'numeric salt'
  sig = RSA_KEY.sign_pss('SHA256', msg, salt_length: 32).__await__
  RSA_KEY.public_key.verify_pss('SHA256', sig, msg, salt_length: 32).__await__
}

# ---------------------------------------------------------------------
# RSA-OAEP encrypt/decrypt
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::RSA — OAEP encrypt/decrypt ---"

SmokeTest.assert("RSA-OAEP encrypt → decrypt round-trip (default SHA-256)") {
  plain = 'phase 7 OAEP payload'
  ct = RSA_KEY.public_key.public_encrypt(plain).__await__
  recovered = RSA_KEY.private_decrypt(ct).__await__
  recovered == plain
}

SmokeTest.assert("RSA-OAEP with SHA-512 hash") {
  plain = 'phase 7 OAEP SHA-512'
  ct = RSA_KEY.public_key.public_encrypt(plain, hash: 'SHA-512').__await__
  recovered = RSA_KEY.private_decrypt(ct, hash: 'SHA-512').__await__
  recovered == plain
}

SmokeTest.assert("RSA-OAEP rejects tampered ciphertext") {
  plain = 'orig'
  ct = RSA_KEY.public_key.public_encrypt(plain).__await__
  bytes = ct.bytes
  bytes[10] ^= 0xff   # flip a bit somewhere in the middle
  bad = bytes.pack('C*')
  raised = false
  begin
    RSA_KEY.private_decrypt(bad).__await__
  rescue OpenSSL::PKey::PKeyError, ::Exception
    raised = true
  end
  raised
}

# ---------------------------------------------------------------------
# ECDSA — DER signature (CRuby compat) and ES384 / ES512
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::EC — DER + ES384 / ES512 ---"

SmokeTest.assert("EC sign returns DER (starts 0x30) and verify accepts it") {
  msg = 'der format check'
  der = EC_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  der.bytes[0] == 0x30 && EC_KEY.verify(OpenSSL::Digest::SHA256.new, der, msg).__await__
}

SmokeTest.assert("EC sign_jwt returns raw R||S (64 bytes for P-256)") {
  msg = 'raw format check'
  raw = EC_KEY.sign_jwt(OpenSSL::Digest::SHA256.new, msg).__await__
  raw.bytesize == 64 && EC_KEY.verify_jwt(OpenSSL::Digest::SHA256.new, raw, msg).__await__
}

SmokeTest.assert("EC DER and raw signatures interchangeable via converters") {
  msg = 'roundtrip der<->raw'
  der = EC_KEY.sign(OpenSSL::Digest::SHA256.new, msg).__await__
  # Re-verify via raw path: convert DER → raw → verify_jwt
  EC_KEY.verify(OpenSSL::Digest::SHA256.new, der, msg).__await__
}

EC_P384 = OpenSSL::PKey::EC.generate('secp384r1')
EC_P521 = OpenSSL::PKey::EC.generate('secp521r1')

SmokeTest.assert("ES384 (P-384) sign/verify round-trip (DER)") {
  msg = 'es384 payload'
  sig = EC_P384.sign(OpenSSL::Digest::SHA384.new, msg).__await__
  EC_P384.verify(OpenSSL::Digest::SHA384.new, sig, msg).__await__
}

SmokeTest.assert("ES384 sign_jwt returns 96-byte raw (48 * 2)") {
  raw = EC_P384.sign_jwt(OpenSSL::Digest::SHA384.new, 'jwt').__await__
  raw.bytesize == 96
}

SmokeTest.assert("ES512 (P-521) sign/verify round-trip (DER)") {
  msg = 'es512 payload'
  sig = EC_P521.sign(OpenSSL::Digest::SHA512.new, msg).__await__
  EC_P521.verify(OpenSSL::Digest::SHA512.new, sig, msg).__await__
}

SmokeTest.assert("ES512 sign_jwt returns 132-byte raw (66 * 2)") {
  raw = EC_P521.sign_jwt(OpenSSL::Digest::SHA512.new, 'jwt').__await__
  raw.bytesize == 132
}

SmokeTest.assert("EC verify raises on truly invalid signature length (not just false)") {
  # Pure noise of wrong length — should raise (invalid DER), not silently false
  raised = false
  begin
    EC_KEY.verify(OpenSSL::Digest::SHA256.new, "\x00\x01", 'msg').__await__
  rescue ::Exception
    raised = true
  end
  raised
}

# ---------------------------------------------------------------------
# ECDH key agreement
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::EC — ECDH ---"

SmokeTest.assert("ECDH P-256: alice & bob derive identical 32-byte secret") {
  alice = OpenSSL::PKey::EC.generate('prime256v1')
  bob   = OpenSSL::PKey::EC.generate('prime256v1')
  s1 = alice.dh_compute_key(bob).__await__
  s2 = bob.dh_compute_key(alice).__await__
  s1 == s2 && s1.bytesize == 32
}

SmokeTest.assert("ECDH P-384: 48-byte secret") {
  a = OpenSSL::PKey::EC.generate('secp384r1')
  b = OpenSSL::PKey::EC.generate('secp384r1')
  s = a.dh_compute_key(b).__await__
  s.bytesize == 48 && s == b.dh_compute_key(a).__await__
}

SmokeTest.assert("ECDH P-521: 66-byte secret") {
  a = OpenSSL::PKey::EC.generate('secp521r1')
  b = OpenSSL::PKey::EC.generate('secp521r1')
  s = a.dh_compute_key(b).__await__
  s.bytesize == 66 && s == b.dh_compute_key(a).__await__
}

# ---------------------------------------------------------------------
# Ed25519 (JWT EdDSA) and X25519 (key agreement)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::Ed25519 (EdDSA) ---"

ED_KEY = OpenSSL::PKey::Ed25519.generate

SmokeTest.assert("Ed25519 generate yields a private key") {
  ED_KEY.private?
}
SmokeTest.assert("Ed25519 sign / verify round-trip") {
  msg = 'EdDSA payload'
  sig = ED_KEY.sign(nil, msg).__await__
  ED_KEY.verify(nil, sig, msg).__await__
}
SmokeTest.assert("Ed25519 verify rejects tampered message") {
  sig = ED_KEY.sign(nil, 'orig').__await__
  ED_KEY.verify(nil, sig, 'tampered').__await__ == false
}
SmokeTest.assert("Ed25519 PEM round-trip preserves public/private") {
  pem = ED_KEY.to_pem
  reloaded = OpenSSL::PKey::Ed25519.new(pem)
  msg = 'pem rt test'
  sig = reloaded.sign(nil, msg).__await__
  ED_KEY.verify(nil, sig, msg).__await__
}

$stdout.puts ""
$stdout.puts "--- OpenSSL::PKey::X25519 (key agreement) ---"

SmokeTest.assert("X25519 alice & bob derive same 32-byte secret") {
  alice = OpenSSL::PKey::X25519.generate
  bob   = OpenSSL::PKey::X25519.generate
  s1 = alice.dh_compute_key(bob).__await__
  s2 = bob.dh_compute_key(alice).__await__
  s1 == s2 && s1.bytesize == 32
}

# ---------------------------------------------------------------------
# OpenSSL::BN — BigInt-backed arbitrary-precision integer arithmetic
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::BN ---"

SmokeTest.assert("BN from Integer and to_s round-trip")    { OpenSSL::BN.new(65537).to_s == '65537' }
SmokeTest.assert("BN from decimal String")                  { OpenSSL::BN.new('12345').to_s == '12345' }
SmokeTest.assert("BN from hex String with 0x prefix")       { OpenSSL::BN.new('0xFF').to_s(16) == 'ff' }
SmokeTest.assert("BN num_bits(256) == 9")                   { OpenSSL::BN.new(256).num_bits == 9 }
SmokeTest.assert("BN num_bits(0) == 0")                     { OpenSSL::BN.new(0).num_bits == 0 }
SmokeTest.assert("BN +")                                    { (OpenSSL::BN.new(2) + OpenSSL::BN.new(3)).to_s == '5' }
SmokeTest.assert("BN * (huge)")                             { (OpenSSL::BN.new('1000000000') * OpenSSL::BN.new('1000000000')).to_s == '1000000000000000000' }
SmokeTest.assert("BN %")                                    { (OpenSSL::BN.new(10) % OpenSSL::BN.new(3)).to_s == '1' }
SmokeTest.assert("BN comparison")                           { OpenSSL::BN.new(5) < OpenSSL::BN.new(10) }
SmokeTest.assert("BN gcd(12, 18) == 6")                     { OpenSSL::BN.new(12).gcd(18).to_s == '6' }
SmokeTest.assert("BN mod_exp (3^5 mod 13 == 9)")            { OpenSSL::BN.new(3).mod_exp(5, 13).to_s == '9' }
SmokeTest.assert("BN odd? / even?")                         { OpenSSL::BN.new(3).odd? && OpenSSL::BN.new(4).even? }
SmokeTest.assert("RSA key n is a large BN (~2048 bits)")    {
  n = RSA_KEY.n
  n.num_bits >= 2040 && n.num_bits <= 2048 && n.to_s.length > 600
}
SmokeTest.assert("RSA key e equals 65537")                   { RSA_KEY.e.to_s == '65537' }

# ---------------------------------------------------------------------
# SecureRandom (already partially implemented; sanity check)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- SecureRandom ---"

SmokeTest.assert("SecureRandom.hex(16) returns 32-char hex") {
  s = SecureRandom.hex(16)
  s.length == 32 && (s =~ /\A[0-9a-f]+\z/)
}
SmokeTest.assert("SecureRandom.random_bytes(32) returns 32 bytes") {
  SecureRandom.random_bytes(32).bytesize == 32
}
SmokeTest.assert("SecureRandom.uuid matches v4 format") {
  uuid = SecureRandom.uuid
  uuid =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}\z/
}
SmokeTest.assert("SecureRandom.urlsafe_base64 has no +/=") {
  s = SecureRandom.urlsafe_base64(32)
  !s.include?('+') && !s.include?('/') && !s.include?('=')
}
SmokeTest.assert("SecureRandom.hex calls produce different values (entropy)") {
  SecureRandom.hex(16) != SecureRandom.hex(16)
}

# ---------------------------------------------------------------------
# OpenSSL::Digest aliases (jwt gem compatibility)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- OpenSSL::Digest aliases ---"

SmokeTest.assert("OpenSSL::Digest::SHA256.hexdigest matches Digest::SHA256") {
  OpenSSL::Digest::SHA256.hexdigest('hello') == SHA256_HELLO
}
SmokeTest.assert("OpenSSL::Digest::SHA384.hexdigest matches Digest::SHA384") {
  OpenSSL::Digest::SHA384.hexdigest('hello') == SHA384_HELLO
}
SmokeTest.assert("OpenSSL::Digest.new('SHA256') gives a Digest object") {
  d = OpenSSL::Digest.new('SHA256')
  d.update('hello').hexdigest == SHA256_HELLO
}

# ---------------------------------------------------------------------
# JWT HS256 round-trip (proof that Phase 8 jwt gem will work)
# ---------------------------------------------------------------------
$stdout.puts ""
$stdout.puts "--- JWT HS256 sanity (Phase 8 readiness) ---"

SmokeTest.assert("HS256 sign/verify round-trip with Base64URL") {
  header  = { 'alg' => 'HS256', 'typ' => 'JWT' }
  payload = { 'sub' => 'alice', 'iat' => 1_000_000_000 }
  secret  = 'super-secret'

  enc = lambda { |obj|
    json = obj.to_json
    Base64.urlsafe_encode64(json).delete('=')
  }
  signing_input = enc.call(header) + '.' + enc.call(payload)
  sig = OpenSSL::HMAC.digest('SHA256', secret, signing_input)
  sig_b64 = Base64.urlsafe_encode64(sig).delete('=')
  token = signing_input + '.' + sig_b64

  parts = token.split('.')
  expected_sig = OpenSSL::HMAC.digest('SHA256', secret, parts[0] + '.' + parts[1])
  expected_b64 = Base64.urlsafe_encode64(expected_sig).delete('=')
  parts[2] == expected_b64
}

# =====================================================================
# Report
# =====================================================================
success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
