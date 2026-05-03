# Sinatra with Email

This example shows the Workers Email binding from plain Sinatra + Ruby.
The app source keeps the same synchronous shape you would expect from a
small Sinatra endpoint.

## Route shape
```ruby
post '/send' do
  mailer = Cloudflare::Email.new(env.SEND_EMAIL)
  result = mailer.send(...)
  { ok: true }.to_json
end
```

## How it works

1. `homura build` parses your Ruby files with the `parser` gem
2. The `AsyncRegistry` knows that `env.SEND_EMAIL` returns a `Cloudflare::Email`
   binding, and that `Cloudflare::Email#send` is async
3. The build output handles the Workers async boundary for the call sites
   that need it
4. Opal compiles the transformed source for the Worker runtime

## Prerequisites

- Ruby 3.4+
- Node 22+
- `wrangler` CLI logged in
- A Cloudflare Email Workers binding (see `wrangler.toml`)

## Build & run

```bash
cd examples/sinatra-with-email
bundle install
bundle exec rake dev    # build + npx wrangler dev --local
```

To deploy: `bundle exec rake deploy` (or `npm run deploy`).

## Test

```bash
# Health check
curl http://127.0.0.1:8787/

# Send an email (replace with your verified sender domain)
curl -X POST http://127.0.0.1:8787/send \
  -d 'to=you@example.com' \
  -d 'subject=Hello from homura' \
  -d 'text=Plain Sinatra source on Workers'
```

## Files

| File | Purpose |
|---|---|
| `app.rb` | Your application — pure Ruby, no Cloudflare-specific syntax |
| `Gemfile` | Pins the homura gems (use `gem install --local` for standalone) |
| `wrangler.toml` | Workers config with `send_email` binding |
