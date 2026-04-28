# auth-otp

> Email OTP login on Cloudflare Workers — OTP rows in **D1**, mail
> through [**mailpit**](https://mailpit.axllent.org/) in development,
> session via an **HMAC-signed cookie**.

In production you swap the mailpit HTTP endpoint for SES / SendGrid /
Resend / Cloudflare Email Workers; everything else is the same code.

## What this shows

- A Sinatra app handling a real auth flow (`/login` → `/verify` → `/`).
- D1-backed OTP storage with TTL via the `expires_at` column.
- `format('%06d', SecureRandom.random_number(1_000_000))` — the canonical
  Ruby idiom; **really returns a uniform 6-digit OTP** on Workers, not
  always-zero like older opal-homura builds.
- HMAC-signed session cookie with a `+`-containing email — round-trips
  intact thanks to `sinatra-homura` 0.2.17's `parse_cookies_header`
  patch (`CGI.unescapeURIComponent`, no form-data `+` → space).
- Worker → mailpit transport via `Cloudflare::HTTP.fetch` to the local
  HTTP API (`POST http://127.0.0.1:8025/api/v1/send`).
- Two end-to-end harnesses, both Ruby:
  - `rake e2e` (Net::HTTP) for CI-friendly smoke.
  - `rake e2e:headed` (`playwright-ruby-client` + Chromium) for visual
    confirmation, with PNG snapshots and a `.webm` recording per run.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/` | Logged-in: `Hello <email>!` + logout button. Logged-out: link to `/login`. |
| `GET`  | `/login` | Email entry form. |
| `POST` | `/login` | Issue a 6-digit OTP, persist `(email, code, expires_at)` in D1, send a mail through mailpit, redirect to `/verify?email=...`. |
| `GET`  | `/verify` | Form for the 6-digit code. |
| `POST` | `/verify` | Match the latest non-expired row for `email`; on success, set a signed `session` cookie and redirect to `/`. |
| `POST` | `/logout` | Drop the cookie, redirect to `/login`. |

## Layout

```
auth-otp/
├── Gemfile                       # + playwright-ruby-client (development)
├── Rakefile                      # build/dev/deploy + db:migrate:* + mailpit:* + e2e + e2e:headed
├── wrangler.toml                 # D1 binding "DB" → database "auth-otp"
├── app/app.rb                    # routes + signed-cookie helpers
├── views/{layout,index,login,verify}.erb
├── db/migrate/
│   ├── 001_create_otps.rb        # Sequel DSL
│   └── 001_create_otps.sql       # compiled output
├── public/robots.txt
└── tmp/e2e-headed/               # screenshots + .webm from `rake e2e:headed`
```

## End-to-end flow

```
                  ┌────────────────────┐  fetch http://127.0.0.1:8025/api/v1/send
       /login ───►│  Cloudflare Worker │ ──────────────────────────────────────────►  mailpit (8025)
                  │  (Sinatra, D1)     │                                                 │
                  └────────────────────┘                                                 │
                          │                                                              │
                  insert OTP into D1                                                     │
                          │                                                              │
                       redirect /verify?email=...                                        │
                          │                                                              ▼
       /verify ─► validate code → set Set-Cookie: session=<email>.<HMAC> → redirect /
```

## Code highlights

```ruby
def generate_otp
  format('%06d', SecureRandom.random_number(1_000_000))   # standard Ruby idiom
end

def sign_email(email)
  OpenSSL::HMAC.hexdigest('SHA256', SESSION_SECRET, email)
end

def encode_session_token(email)
  "#{email}.#{sign_email(email)}"                          # plain email, no hex shim
end

post '/login' do
  email = params[:email].to_s.strip
  halt 422, 'invalid email' unless email.match?(EMAIL_RE)
  code = generate_otp
  db.execute_insert(
    'INSERT INTO otps (email, code, expires_at) VALUES (?, ?, ?)',
    [email, code, Time.now.to_i + 300]
  )
  send_otp_via_mailpit(email, code)
  redirect "/verify?email=#{Rack::Utils.escape(email)}"
end
```

## Run it (development)

```bash
cd examples/auth-otp
bundle install
npm install

bundle exec rake db:migrate:local         # create otps table in local D1
bundle exec rake mailpit:start            # spawns mailpit on 127.0.0.1:1025/8025
bundle exec rake build
bundle exec rake dev                      # http://auth-otp.localhost:1355/
```

Now:

- Open <http://auth-otp.localhost:1355/login>, type any email, submit.
- Open <http://127.0.0.1:8025> (mailpit web UI) and copy the 6-digit code
  out of the received message.
- Paste it into `/verify`, hit submit, you're logged in.

## End-to-end with Net::HTTP

```bash
bundle exec rake e2e
# [e2e] base=http://auth-otp.localhost:1355 email=demo+1777289470@example.com
# [e2e] /login → 200
# [e2e] mailpit mail received id=... otp=310597
# [e2e] /verify → 303
# [e2e] / shows logged-in email
# [e2e] /logout → 303
# E2E OK: email=demo+1777289470@example.com, otp=310597
```

Run it twice in a row and the OTPs are different — proof that
`SecureRandom.random_number` is producing real entropy.

## End-to-end with a real browser (headed)

```bash
bundle exec rake e2e:headed
```

This launches Chromium through `playwright-ruby-client`, runs the
exact same flow with `slowMo: 350` so you can see it, and writes:

- `tmp/e2e-headed/01-top-unauth.png`
- `tmp/e2e-headed/02-login-filled.png`
- `tmp/e2e-headed/03-after-login.png`
- `tmp/e2e-headed/04-verify-filled.png`
- `tmp/e2e-headed/05-after-verify.png`  ← `Hello demo+...@example.com!`
- `tmp/e2e-headed/06-after-logout.png`
- `tmp/e2e-headed/page@<hash>.webm`     ← full recording

## Production switch-over

Two changes are enough for production:

1. **Mail transport.** Replace the body of `send_otp_via_mailpit` with a
   call to your provider — SES / SendGrid / Resend / Cloudflare Email
   Workers — through `Cloudflare::HTTP.fetch`.

2. **`SESSION_SECRET`.** Set it as a Wrangler secret:

   ```bash
   npx wrangler secret put SESSION_SECRET
   ```

The remote D1 setup is the standard `homura new --with-db` flow:

```bash
npx wrangler d1 create auth-otp                     # one-time
# paste the database_id into wrangler.toml
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
