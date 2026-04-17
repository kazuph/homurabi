# frozen_string_literal: true
# await: true
#
# homurabi patch: Phase 8 — vendored entry for jwt/ruby-jwt v2.9.3 adapted
# to Opal + Cloudflare Workers. Uses OpenSSL primitives we implemented in
# Phase 7; sign/verify for RS/PS/ES/EdDSA hit Web Crypto subtle which is
# async, so the jwt algorithm classes (vendor/jwt/jwa/*.rb) are `# await: true`
# and add `.__await__` at the subtle call boundary. The gem's public surface
# (`JWT.encode` / `JWT.decode`) is therefore async — callers in Sinatra routes
# append `.__await__` exactly like they do for D1/KV/R2/Cipher.

require 'jwt/version'
require 'jwt/base64'
require 'jwt/json'
require 'jwt/configuration'
require 'jwt/deprecations'
require 'jwt/error'
require 'jwt/encode'
require 'jwt/decode'
require 'jwt/jwk'
require 'jwt/claims'
require 'jwt/claims_validator'
require 'jwt/verify'

# JSON Web Token implementation (ruby-jwt v2.9.3, homurabi-patched for Opal).
# https://tools.ietf.org/html/rfc7519
module JWT
  extend ::JWT::Configuration

  module_function

  # homurabi patch: `.__await__` on Encode#segments — the encode pipeline
  # is async because RS/PS/ES/EdDSA signing hits Web Crypto subtle. HMAC
  # stays sync; `__await__` on a non-Promise is a no-op so the same
  # code path serves both algorithm families.
  def encode(payload, key, algorithm = 'HS256', header_fields = {})
    Encode.new(payload: payload,
               key: key,
               algorithm: algorithm,
               headers: header_fields).segments.__await__
  end

  # homurabi patch: `.__await__` on Decode#decode_segments — verify hits
  # subtle for non-HMAC algos and returns a Promise. HMAC stays sync.
  def decode(jwt, key = nil, verify = true, options = {}, &keyfinder) # rubocop:disable Style/OptionalBooleanParameter
    Deprecations.context do
      Decode.new(jwt, key, verify, configuration.decode.to_h.merge(options), &keyfinder).decode_segments.__await__
    end
  end
end
