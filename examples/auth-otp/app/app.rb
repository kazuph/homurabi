# await: all, call, fetch, get_first_row, execute, execute_insert, open, run, send, sleep
# frozen_string_literal: true
require 'sinatra/base'
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

    # Are we serving from a local dev hostname (`*.localhost` via portless,
    # `127.0.0.1`, plain `localhost`)? Used to gate the mailpit-related copy
    # and the OTP-on-screen fallback so production never leaks them.
    def dev_host?
      host = request.host.to_s
      host == 'localhost' ||
        host == '127.0.0.1' ||
        host.end_with?('.localhost')
    end

    # Read a Cloudflare Workers env var / secret. Wrangler `[vars]` and
    # `wrangler secret put` both surface as plain JS properties on the
    # bound env object (`env['cloudflare.env']`). Returns '' when the
    # binding hasn't been configured.
    def cf_env_var(name)
      cf_env = env['cloudflare.env']
      return '' unless cf_env
      `(#{cf_env}[#{name}] || '')`.to_s.strip
    end

    # Should we actually send mail to `email`? Reads `HOMURA_MAIL_ALLOWLIST`
    # (comma-separated, configured with `wrangler secret put`) as the
    # production allowlist. In dev we always send (mailpit is local-only).
    # When the allowlist is empty we send to anyone (so a fresh fork
    # without env config still works in dev).
    def mail_allowed?(email)
      return true if dev_host?
      list = cf_env_var('HOMURA_MAIL_ALLOWLIST').split(',').map { |s| s.strip.downcase }.reject(&:empty?)
      return true if list.empty?
      list.include?(email.to_s.strip.downcase)
    end

    # Send the OTP. In development (`*.localhost` / 127.0.0.1) we POST to
    # the local mailpit HTTP Send API so the demo stays self-contained;
    # in production we go through the Cloudflare Email Workers binding
    # (`env.SEND_EMAIL` → `Cloudflare::Email`) so a real email arrives in
    # the user's inbox. Returns [ok, error_message].
    def send_otp_email(email, code)
      if dev_host?
        send_otp_via_mailpit(email, code)
      else
        send_otp_via_cloudflare_email(email, code)
      end
    end

    # Worker → 127.0.0.1:8025 fetch works in `wrangler dev --local` mode.
    def send_otp_via_mailpit(email, code)
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

    # Production: Cloudflare Email Workers send via the SEND_EMAIL binding.
    # The destination address must be verified in Cloudflare Email Routing,
    # and the `from` address must come from a domain you've added there.
    def send_otp_via_cloudflare_email(email, code)
      mailer = env['cloudflare.SEND_EMAIL']
      return [false, 'SEND_EMAIL binding missing'] unless mailer && mailer.available?

      from = cf_env_var('HOMURA_MAIL_FROM')
      from = 'noreply@example.com' if from.empty?
      mailer.send(
        to: email,
        from: from,
        subject: 'Your one-time code',
        text: "Your code: #{code} (valid 5min)\n\nIf you did not request this, ignore this email.\n"
      )
      [true, nil]
    rescue Cloudflare::Email::Error => e
      [false, "Cloudflare Email send failed: #{e.message}"]
    rescue => e
      [false, "Cloudflare Email send failed: #{e.message}"]
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

    @title = 'Verify OTP — auth-otp demo'
    @issued_email = email
    @issued_code  = nil

    if mail_allowed?(email)
      ok, err = send_otp_email(email, code)
      if ok
        @mail_notice = if dev_host?
                         "メールを確認してください (#{email})。届かない場合は mailpit Web UI で確認: http://127.0.0.1:8025/"
                       else
                         "メールを確認してください (#{email})。"
                       end
      elsif dev_host?
        # Dev-only fallback: show the OTP on screen so the demo keeps working
        # even if mailpit is offline. NEVER do this in production — it leaks
        # the one-time code.
        @issued_code = code
        @mail_error  = err
      else
        @mail_error = 'メール送信に失敗しました。しばらくしてからもう一度お試しください。'
      end
    else
      # Address not on the allowlist (or no allowlist configured in dev
      # → see mail_allowed? for the dev policy). Render the same
      # success-shaped UI as a real send so we never leak whether an
      # address is permitted. The OTP row was already inserted, so
      # /verify still rejects mismatched codes naturally.
      @mail_notice = "メールを確認してください (#{email})。"
    end

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
