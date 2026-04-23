# Minimal Sinatra with Email — Phase 17.5 Auto-Await Demo

This example shows the **Phase 17.5** user experience: you write plain
Sinatra + Ruby, and the `homura build` pipeline automatically
inserts `.__await__` where needed.

## What makes this different from pre-17.5

**Before (manual await):**
```ruby
# await: send
post '/send' do
  mailer = Cloudflare::Email.new(env.SEND_EMAIL)
  result = mailer.send(...).__await__
  { ok: true }.to_json
end
```

**After (Phase 17.5 — auto-await):**
```ruby
post '/send' do
  mailer = Cloudflare::Email.new(env.SEND_EMAIL)
  result = mailer.send(...)
  { ok: true }.to_json
end
```

No `.__await__`. No `# await:` magic comment. Just Ruby.

## How it works

1. `homura build` parses your Ruby files with the `parser` gem
2. The `AsyncRegistry` knows that `env.SEND_EMAIL` returns a `Cloudflare::Email`
   binding, and that `Cloudflare::Email#send` is async
3. The analyzer taints the receiver chain and inserts `.__await__` at the
   exact call sites that need it
4. Opal compiles the transformed source, which now contains the await
   calls inside an async function wrapper

## Prerequisites

- Ruby 3.4+
- Node 22+
- `wrangler` CLI logged in
- A Cloudflare Email Workers binding (see `wrangler.toml`)

## Build & run

```bash
cd examples/minimal-sinatra-with-email
bundle install
bundle exec homura build --standalone
npx wrangler dev --port 8787
```

## Test

```bash
# Health check
curl http://127.0.0.1:8787/

# Send an email (replace with your verified sender domain)
curl -X POST http://127.0.0.1:8787/send \
  -d 'to=you@example.com' \
  -d 'subject=Hello from Phase 17.5' \
  -d 'text=No __await__ anywhere!'
```

## Files

| File | Purpose |
|---|---|
| `app.rb` | Your application — pure Ruby, no Cloudflare-specific syntax |
| `Gemfile` | Pins the homura gems (use `gem install --local` for standalone) |
| `wrangler.toml` | Workers config with `send_email` binding |
