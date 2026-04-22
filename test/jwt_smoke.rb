# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 8 — JWT smoke tests.
#
# Runs against the vendored ruby-jwt (vendor/jwt/) built on top of Phase 7
# OpenSSL primitives. Covers every JWT-spec algorithm we support:
#
#   - HS256 / HS384 / HS512 (HMAC, sync node:crypto)
#   - RS256 / RS384 / RS512 (RSASSA-PKCS1-v1_5, async Web Crypto subtle)
#   - PS256 / PS384 / PS512 (RSASSA-PSS, async subtle)
#   - ES256 / ES384 / ES512 (ECDSA P-256/384/521, raw R||S via subtle)
#   - EdDSA                 (Ed25519, async subtle)
#
# For each algo: (a) encode→decode round-trip, (b) tampered-signature
# rejection. Plus a few generic claims / header / none-alg edge cases.
#
# Usage:
#   npm run test:jwt
#   npm test           # full suite (smoke + http + crypto + jwt)

require 'json'
require 'digest'
require 'digest/sha2'
require 'openssl'
require 'securerandom'
require 'base64'
require 'jwt'

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

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
    $stdout.puts ''
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts 'Failures:'
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# Helper: flip the last base64url char of a token's signature segment.
# Returns a token byte-identical except for one char in the sig, which
# guarantees the decoded sig bytes differ by at least one byte.
def tamper(token)
  parts = token.split('.')
  last = parts[2]
  flip = last[-1] == 'A' ? 'B' : 'A'
  parts[2] = last[0..-2] + flip
  parts.join('.')
end

PAYLOAD = { 'sub' => 'alice', 'iat' => 1_000_000_000, 'role' => 'admin' }.freeze

$stdout.puts '=== homura Phase 8 — JWT smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# HMAC — HS256 / HS384 / HS512
# ---------------------------------------------------------------------
$stdout.puts '--- HS256/384/512 (HMAC) ---'

%w[HS256 HS384 HS512].each do |alg|
  secret = 'super-secret-key-' + alg.downcase
  SmokeTest.assert("#{alg} encode/decode round-trip") {
    token = JWT.encode(PAYLOAD, secret, alg).__await__
    decoded, header = JWT.decode(token, secret, true, algorithm: alg).__await__
    decoded == PAYLOAD && header['alg'] == alg
  }
  SmokeTest.assert("#{alg} rejects tampered signature") {
    token = JWT.encode(PAYLOAD, secret, alg).__await__
    bad   = tamper(token)
    raised = false
    begin
      JWT.decode(bad, secret, true, algorithm: alg).__await__
    rescue JWT::VerificationError
      raised = true
    end
    raised
  }
  SmokeTest.assert("#{alg} rejects wrong secret") {
    token = JWT.encode(PAYLOAD, secret, alg).__await__
    raised = false
    begin
      JWT.decode(token, 'not-the-secret', true, algorithm: alg).__await__
    rescue JWT::VerificationError
      raised = true
    end
    raised
  }
end

# ---------------------------------------------------------------------
# RSA — RS256 / RS384 / RS512
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- RS256/384/512 (RSASSA-PKCS1-v1_5) ---'

RSA_KEY = OpenSSL::PKey::RSA.new(2048)

%w[RS256 RS384 RS512].each do |alg|
  SmokeTest.assert("#{alg} encode/decode round-trip") {
    token = JWT.encode(PAYLOAD, RSA_KEY, alg).__await__
    decoded, header = JWT.decode(token, RSA_KEY.public_key, true, algorithm: alg).__await__
    decoded == PAYLOAD && header['alg'] == alg
  }
  SmokeTest.assert("#{alg} rejects tampered signature") {
    token = JWT.encode(PAYLOAD, RSA_KEY, alg).__await__
    raised = false
    begin
      JWT.decode(tamper(token), RSA_KEY.public_key, true, algorithm: alg).__await__
    rescue JWT::VerificationError
      raised = true
    end
    raised
  }
end

SmokeTest.assert('RS256 accepts private key for verification (CRuby compat)') {
  token = JWT.encode(PAYLOAD, RSA_KEY, 'RS256').__await__
  decoded, = JWT.decode(token, RSA_KEY, true, algorithm: 'RS256').__await__
  decoded == PAYLOAD
}

# ---------------------------------------------------------------------
# RSA-PSS — PS256 / PS384 / PS512
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- PS256/384/512 (RSASSA-PSS) ---'

%w[PS256 PS384 PS512].each do |alg|
  SmokeTest.assert("#{alg} encode/decode round-trip") {
    token = JWT.encode(PAYLOAD, RSA_KEY, alg).__await__
    decoded, header = JWT.decode(token, RSA_KEY.public_key, true, algorithm: alg).__await__
    decoded == PAYLOAD && header['alg'] == alg
  }
  SmokeTest.assert("#{alg} rejects tampered signature") {
    token = JWT.encode(PAYLOAD, RSA_KEY, alg).__await__
    raised = false
    begin
      JWT.decode(tamper(token), RSA_KEY.public_key, true, algorithm: alg).__await__
    rescue JWT::VerificationError
      raised = true
    end
    raised
  }
end

# ---------------------------------------------------------------------
# ECDSA — ES256 / ES384 / ES512
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- ES256/384/512 (ECDSA, raw R||S) ---'

EC_BY_ALG = {
  'ES256' => OpenSSL::PKey::EC.generate('prime256v1'),
  'ES384' => OpenSSL::PKey::EC.generate('secp384r1'),
  'ES512' => OpenSSL::PKey::EC.generate('secp521r1')
}.freeze

%w[ES256 ES384 ES512].each do |alg|
  key = EC_BY_ALG[alg]
  SmokeTest.assert("#{alg} encode/decode round-trip") {
    token = JWT.encode(PAYLOAD, key, alg).__await__
    decoded, header = JWT.decode(token, key, true, algorithm: alg).__await__
    decoded == PAYLOAD && header['alg'] == alg
  }
  SmokeTest.assert("#{alg} rejects tampered signature") {
    token = JWT.encode(PAYLOAD, key, alg).__await__
    raised = false
    begin
      JWT.decode(tamper(token), key, true, algorithm: alg).__await__
    rescue ::Exception
      # subtle may throw (invalid signature length) OR return false;
      # either outcome counts as rejection. We rescue broadly.
      raised = true
    end
    raised
  }
end

SmokeTest.assert('ES256 rejects ES384 key (curve/alg mismatch)') {
  token = JWT.encode(PAYLOAD, EC_BY_ALG['ES256'], 'ES256').__await__
  raised = false
  begin
    JWT.decode(token, EC_BY_ALG['ES384'], true, algorithm: 'ES256').__await__
  rescue ::Exception
    raised = true
  end
  raised
}

# ---------------------------------------------------------------------
# EdDSA — Ed25519
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- EdDSA (Ed25519) ---'

ED_KEY = OpenSSL::PKey::Ed25519.generate

SmokeTest.assert('EdDSA encode/decode round-trip') {
  token = JWT.encode(PAYLOAD, ED_KEY, 'EdDSA').__await__
  decoded, header = JWT.decode(token, ED_KEY, true, algorithm: 'EdDSA').__await__
  decoded == PAYLOAD && header['alg'] == 'EdDSA'
}
SmokeTest.assert('EdDSA rejects tampered signature') {
  token = JWT.encode(PAYLOAD, ED_KEY, 'EdDSA').__await__
  raised = false
  begin
    JWT.decode(tamper(token), ED_KEY, true, algorithm: 'EdDSA').__await__
  rescue JWT::VerificationError
    raised = true
  end
  raised
}
SmokeTest.assert('ED25519 alias for EdDSA works') {
  token = JWT.encode(PAYLOAD, ED_KEY, 'ED25519').__await__
  decoded, header = JWT.decode(token, ED_KEY, true, algorithm: 'ED25519').__await__
  decoded == PAYLOAD && header['alg'] == 'ED25519'
}

# ---------------------------------------------------------------------
# Algorithm confusion / header tampering
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- algo-confusion + header edge cases ---'

SmokeTest.assert('decode rejects alg:none when not allowed') {
  header  = { 'alg' => 'none', 'typ' => 'JWT' }
  payload = PAYLOAD
  enc     = ->(obj) { Base64.urlsafe_encode64(obj.to_json).delete('=') }
  token   = enc.call(header) + '.' + enc.call(payload) + '.'
  raised  = false
  begin
    JWT.decode(token, nil, true, algorithm: 'HS256').__await__
  rescue JWT::IncorrectAlgorithm, JWT::DecodeError
    raised = true
  end
  raised
}

SmokeTest.assert('decode with algorithm mismatch is rejected (HS256 token, RS256 expected)') {
  token = JWT.encode(PAYLOAD, 'secret', 'HS256').__await__
  raised = false
  begin
    JWT.decode(token, RSA_KEY.public_key, true, algorithm: 'RS256').__await__
  rescue JWT::IncorrectAlgorithm
    raised = true
  end
  raised
}

SmokeTest.assert('header_fields extra keys propagate to decoded header') {
  token = JWT.encode(PAYLOAD, 'secret', 'HS256', { 'kid' => 'k-1' }).__await__
  _, header = JWT.decode(token, 'secret', true, algorithm: 'HS256').__await__
  header['kid'] == 'k-1' && header['alg'] == 'HS256'
}

SmokeTest.assert('decode without verify returns segments unchecked') {
  token = JWT.encode(PAYLOAD, 'secret', 'HS256').__await__
  decoded, header = JWT.decode(token, nil, false).__await__
  decoded == PAYLOAD && header['alg'] == 'HS256'
}

SmokeTest.assert('decode raises JWT::DecodeError on malformed input (2 segments)') {
  raised = false
  begin
    JWT.decode('foo.bar', 'secret', true, algorithm: 'HS256').__await__
  rescue JWT::DecodeError
    raised = true
  end
  raised
}

SmokeTest.assert('decode with allowed algorithms array') {
  token = JWT.encode(PAYLOAD, 'secret', 'HS512').__await__
  decoded, header = JWT.decode(token, 'secret', true, algorithms: %w[HS256 HS384 HS512]).__await__
  decoded == PAYLOAD && header['alg'] == 'HS512'
}

# ---------------------------------------------------------------------
# Claims — exp / iat / iss / aud / sub
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- claim verification ---'

SmokeTest.assert('expired token is rejected') {
  payload = { 'sub' => 'alice', 'exp' => Time.now.to_i - 60 }
  token = JWT.encode(payload, 'secret', 'HS256').__await__
  raised = false
  begin
    JWT.decode(token, 'secret', true, algorithm: 'HS256').__await__
  rescue JWT::ExpiredSignature
    raised = true
  end
  raised
}

SmokeTest.assert('future-exp token is accepted') {
  payload = { 'sub' => 'alice', 'exp' => Time.now.to_i + 60 }
  token = JWT.encode(payload, 'secret', 'HS256').__await__
  decoded, = JWT.decode(token, 'secret', true, algorithm: 'HS256').__await__
  decoded['sub'] == 'alice'
}

SmokeTest.assert('nbf in the future is rejected') {
  payload = { 'sub' => 'alice', 'nbf' => Time.now.to_i + 60 }
  token = JWT.encode(payload, 'secret', 'HS256').__await__
  raised = false
  begin
    JWT.decode(token, 'secret', true, algorithm: 'HS256').__await__
  rescue JWT::ImmatureSignature
    raised = true
  end
  raised
}

SmokeTest.assert('issuer verification succeeds when matching') {
  payload = { 'sub' => 'alice', 'iss' => 'homura' }
  token = JWT.encode(payload, 'secret', 'HS256').__await__
  decoded, = JWT.decode(token, 'secret', true,
                        algorithm: 'HS256', iss: 'homura', verify_iss: true).__await__
  decoded['iss'] == 'homura'
}

SmokeTest.assert('issuer verification fails on mismatch') {
  payload = { 'sub' => 'alice', 'iss' => 'other' }
  token = JWT.encode(payload, 'secret', 'HS256').__await__
  raised = false
  begin
    JWT.decode(token, 'secret', true,
               algorithm: 'HS256', iss: 'homura', verify_iss: true).__await__
  rescue JWT::InvalidIssuerError
    raised = true
  end
  raised
}

# =====================================================================
# Report
# =====================================================================
success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
