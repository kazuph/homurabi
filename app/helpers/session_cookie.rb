# frozen_string_literal: true

module Homurabi
  module JwtKeyHelpers
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

  # Custom HMAC-SHA256 signed cookie helpers (sync, with a
  # base64url-encoded `username:exp` payload — not a JWT). Going
  # custom avoids JWT.encode's auto-awaited Promise path, which
  # collides with Sinatra `redirect`'s :halt throw across Opal's
  # async boundary. Constants stay on App (see app.rb) so startup cost
  # stays minimal.
  module SessionCookieInstanceMethods
    def verify_session_cookie(raw)
      return nil unless raw.is_a?(String) && raw.include?('.')
      payload, sig = raw.split('.', 2)
      return nil if payload.nil? || sig.nil? || payload.empty? || sig.empty?
      expected = OpenSSL::HMAC.hexdigest('SHA256', settings.jwt_secret, payload)
      return nil unless Rack::Utils.secure_compare(expected, sig)
      decoded = Base64.urlsafe_decode64(payload) rescue nil
      return nil if decoded.nil?
      username, exp = decoded.split(':', 2)
      return nil if username.nil? || exp.nil?
      return nil if Time.now.to_i > exp.to_i
      username
    end

    def mint_session_cookie(username)
      exp = Time.now.to_i + App::SESSION_COOKIE_TTL
      payload = Base64.urlsafe_encode64("#{username}:#{exp}", padding: false)
      sig = OpenSSL::HMAC.hexdigest('SHA256', settings.jwt_secret, payload)
      "#{payload}.#{sig}"
    end

    def current_session_user
      verify_session_cookie(request.cookies[App::SESSION_COOKIE_NAME].to_s)
    end
  end
end
