# await: all, call, fetch, get_first_row, execute, execute_insert, open, run, sleep
# frozen_string_literal: true
require 'sinatra/cloudflare_workers'
require 'sequel'

class App < Sinatra::Base
  # 5-minute OTP validity window.
  OTP_TTL = 300

  # 7-day login session validity window.
  SESSION_TTL = 7 * 24 * 3600

  # Local mailpit HTTP send API. Worker (`wrangler dev --local`) can reach
  # 127.0.0.1:8025 directly because dev mode runs on the host network.
  MAILPIT_SEND_URL = 'http://127.0.0.1:8025/api/v1/send'

  # HMAC-SHA256 signature length in hex chars. Anchoring the cookie split
  # on a fixed-width tail (instead of `split('.', 2)`) keeps the email part
  # intact even though emails commonly contain `.`.
  HMAC_HEX_LEN = 64

  helpers do
    def db
      d1 = env['cloudflare.DB']
      return nil unless d1
      d1
    end

    def h(s)
      Rack::Utils.escape_html(s.to_s)
    end

    # Constant-time string compare via Rack::Utils.secure_compare; the secret
    # itself comes from ENV['SESSION_SECRET'] when present so deployments can
    # rotate without code edits, and falls back to a clearly-named development
    # default otherwise.
    def session_secret
      ENV['SESSION_SECRET'] || 'dev-secret-change-me'
    end

    # Sign the email with HMAC-SHA256. OpenSSL::HMAC is sync on this stack, so
    # cookie set/verify can stay inside ordinary sync routes (and `redirect`
    # works without async boundary surprises).
    def sign_email(email)
      OpenSSL::HMAC.hexdigest('SHA256', session_secret, email)
    end

    # Build/parse the session cookie value. Format is `<email>.<hex64-sig>`.
    # sinatra-homura 0.2.17 fixes the `+` percent-decode round trip, so we
    # can keep the email plain in the cookie value. We split on the
    # fixed-width HMAC tail because emails commonly contain `.`.
    def encode_session_token(email)
      "#{email}.#{sign_email(email)}"
    end

    # Verify the cookie value, returning the email if valid.
    def verified_email_from_cookie
      raw = request.cookies['session'].to_s
      return nil if raw.length < HMAC_HEX_LEN + 2
      sig   = raw[-HMAC_HEX_LEN, HMAC_HEX_LEN]
      sep   = raw[-(HMAC_HEX_LEN + 1), 1]
      email = raw[0, raw.length - HMAC_HEX_LEN - 1]
      return nil if sep != '.' || email.nil? || email.empty?
      expected = sign_email(email)
      return nil unless Rack::Utils.secure_compare(expected, sig)
      email
    end

    # Generate a 6-digit OTP using Sinatra/Ruby standard form.
    def generate_otp
      format('%06d', SecureRandom.random_number(1_000_000))
    end

    # Send the OTP to mailpit's HTTP Send API. Returns [ok, error_message].
    # Worker → 127.0.0.1:8025 fetch works in `wrangler dev --local` mode.
    def send_otp_email(email, code)
      payload = {
        'From' => { 'Email' => 'no-reply@auth-otp.localhost', 'Name' => 'auth-otp demo' },
        'To'   => [{ 'Email' => email }],
        'Subject' => 'Your one-time code',
        'Text'    => "Your code: #{code} (valid 5min)\n\nIf you did not request this, ignore this email.\n"
      }.to_json

      resp = Cloudflare::HTTP.fetch(
        MAILPIT_SEND_URL,
        method: 'POST',
        headers: { 'content-type' => 'application/json' },
        body: payload
      )
      return [true, nil] if resp.ok?
      [false, "mailpit #{resp.status}: #{resp.body[0, 200]}"]
    rescue => e
      [false, "mailpit fetch failed: #{e.message}"]
    end
  end

  get '/' do
    @title = 'auth-otp demo'
    @email = verified_email_from_cookie
    erb :index, layout: :layout
  end

  get '/_debug/rand' do
    content_type 'application/json'
    bytes = SecureRandom.bytes(4)
    ords = (0...bytes.length).map { |i| bytes[i].ord }
    {
      bytes_class: bytes.class.to_s,
      bytes_length: bytes.length,
      ords: ords,
      hex8: SecureRandom.hex(8),
      random_float: SecureRandom.random_float,
      random_number_1m: SecureRandom.random_number(1_000_000),
      sample_otps: 5.times.map { format('%06d', SecureRandom.random_number(1_000_000)) }
    }.to_json
  end

  get '/login' do
    @title = 'Login — auth-otp demo'
    @notice = params['notice']
    erb :login, layout: :layout
  end

  post '/login' do
    email = params['email'].to_s.strip
    if email.empty? || email.length > 200 || !email.include?('@')
      @title = 'Login — auth-otp demo'
      @login_error = 'valid email is required'
      @form_email = email
      next erb :login, layout: :layout
    end

    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    code = generate_otp
    expires_at = Time.now.to_i + OTP_TTL

    # Persist the OTP. We keep prior unverified rows for the same email
    # rather than upsert; `/verify` queries the latest non-expired row.
    conn.execute_insert(
      'INSERT INTO otps (email, code, expires_at) VALUES (?, ?, ?)',
      [email, code, expires_at]
    )

    ok, err = send_otp_email(email, code)
    unless ok
      # Dev fallback: surface the OTP on screen so the demo keeps working
      # even if mailpit is offline. The error is shown above the code.
      @title = 'Verify OTP — auth-otp demo'
      @issued_email = email
      @issued_code  = code
      @mail_error   = err
      next erb :verify, layout: :layout
    end

    @title = 'Verify OTP — auth-otp demo'
    @issued_email = email
    @issued_code  = nil
    @mail_notice  = "メールを確認してください (#{email})。届かない場合はmailpit Web UIで確認: http://127.0.0.1:8025/"
    erb :verify, layout: :layout
  end

  get '/verify' do
    @title = 'Verify OTP — auth-otp demo'
    @issued_email = params['email'].to_s
    @issued_code  = nil
    erb :verify, layout: :layout
  end

  post '/verify' do
    email = params['email'].to_s.strip
    code  = params['code'].to_s.strip

    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    now = Time.now.to_i
    row = conn.get_first_row(
      'SELECT id, code, expires_at FROM otps WHERE email = ? AND expires_at >= ? ORDER BY id DESC LIMIT 1',
      [email, now]
    )

    if row.nil? || !Rack::Utils.secure_compare(row['code'].to_s, code)
      @title = 'Verify OTP — auth-otp demo'
      @issued_email = email
      @verify_error = 'invalid or expired code'
      next erb :verify, layout: :layout
    end

    # One-shot consumption: drop the row (and any older rows for this email)
    # so the same code can't be replayed.
    conn.execute('DELETE FROM otps WHERE email = ?', [email])

    token = encode_session_token(email)
    response.set_cookie('session', {
      value: token,
      path: '/',
      httponly: true,
      secure: request.scheme == 'https',
      same_site: :lax,
      max_age: SESSION_TTL
    })
    redirect '/', 303
  end

  post '/logout' do
    response.delete_cookie('session', path: '/')
    redirect '/login?notice=logged-out', 303
  end
end
