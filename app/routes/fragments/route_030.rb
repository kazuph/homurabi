# frozen_string_literal: true
# Route fragment 30 — login /login
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
    @title = 'Login — homura'
    @login_error = 'username is required (1-64 chars, no colon)'
    @content = erb :login
    next erb :layout
  end

  # mint_session_cookie is sync (HMAC-SHA256 via node:crypto).
  # Keeping the route body sync lets `redirect` work normally.
  token = mint_session_cookie(username)
  response.set_cookie(App::SESSION_COOKIE_NAME, {
    value: token,
    path: '/',
    httponly: true,
    secure: request.scheme == 'https',
    same_site: :lax,
    max_age: App::SESSION_COOKIE_TTL
  })
  # 303 See Other — explicitly tells the client to follow up with
  # GET, avoiding any ambiguous POST-replay semantics around 302.
  redirect return_to, 303
end
