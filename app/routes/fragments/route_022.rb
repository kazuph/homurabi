# await: true
# frozen_string_literal: true
# Route fragment 22 — api /api/login
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
    'exp'  => Time.now.to_i + App::JWT_ACCESS_TTL
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
      'exp'  => Time.now.to_i + App::JWT_REFRESH_TTL
    }
    kv.put("refresh:#{refresh}", entry.to_json)
  end

  status 201
  resp = {
    'access_token' => access_token,
    'token_type'   => 'Bearer',
    'expires_in'   => App::JWT_ACCESS_TTL,
    'alg'          => alg
  }
  resp['refresh_token'] = refresh if refresh
  resp.to_json
end
