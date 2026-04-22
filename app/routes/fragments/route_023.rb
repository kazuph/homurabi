# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 23 — api /api/me
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
