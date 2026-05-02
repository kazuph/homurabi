# Examples

Twelve fully-working applications built on the published [homura](../) gems.
Each example is a standalone project: its `Gemfile` pins released gems
from RubyGems with no `path:` references back to the monorepo, so any
of them can be copied out of this directory and shipped on its own.

These apps are also the regression fixtures behind the latest gem
releases — every Workers/Opal divergence the four gems absorb has at
least one example that proves the standard Sinatra / Sequel / ERB
idiom works the way the upstream docs say it does.

## What's here

| Example | Stack | Live | Highlights |
|---|---|---|---|
| [`sinatra/`](sinatra/) | Sinatra (single file) | <https://sinatra.kazu-san.workers.dev/> | The classic Sinatra README snippet: `require 'sinatra'` + `get '/frank-says'`. The shortest possible homura app. |
| [`rack/`](rack/) | Rack only | <https://rack.kazu-san.workers.dev/> | Direct Rack response triples with `run ->(env) { ... }`; no Sinatra require. |
| [`classic-top-sinatra/`](classic-top-sinatra/) | Sinatra (single file, JSON) | <https://classic-top-sinatra.kazu-san.workers.dev/> | Same shape as `sinatra/` but emits JSON via `content_type :json`. Dogfoods the classic top-level DSL across the build pipeline. |
| [`sinatra-with-db/`](sinatra-with-db/) | Sinatra + D1 + Sequel | <https://sinatra-with-db.kazu-san.workers.dev/> | Smallest D1-backed Sinatra: `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`, one route, one migration. |
| [`sinatra-with-email/`](sinatra-with-email/) | Sinatra + Cloudflare Email | <https://sinatra-with-email.kazu-san.workers.dev/> | Phase 17.5 auto-await demo — POST `/send` over the `SEND_EMAIL` Cloudflare Email binding, no `.__await__` in source. |
| [`todo-simple/`](todo-simple/) | Sinatra (in-memory) | <https://todo-simple.kazu-san.workers.dev/> | **The smallest stateful example.** One `app.rb`, no `views/`, no D1 — heredoc HTML right next to the routes. Use it when you want to see how little homura needs once you have state. |
| [`todo/`](todo/) | Sinatra + D1 (no ORM) | <https://todo.kazu-san.workers.dev/> | Smallest D1 CRUD. `env['cloudflare.DB']` and the `Cloudflare::D1Database#execute` / `execute_insert` API directly — no Sequel. |
| [`todo-orm/`](todo-orm/) | Sinatra + D1 + Sequel | <https://todo-orm.kazu-san.workers.dev/> | Same TODO domain through `sequel-d1`. Datasets, `.first`, `.update(... Sequel.lit ...)`, migration DSL → wrangler-ready SQL. |
| [`auth-otp/`](auth-otp/) | Sinatra + D1 + mailpit + Playwright | <https://auth-otp.kazu-san.workers.dev/login> | Email OTP login backed by a [mailpit](https://mailpit.axllent.org/) sink in development. HMAC-signed session cookie. `rake e2e` (Net::HTTP) and `rake e2e:headed` (real Chromium) for end-to-end verification. |
| [`blog/`](blog/) | Sinatra + D1 (no ORM) | <https://blog.kazu-san.workers.dev/> | Index / detail / new / proper 404 / delete. Shows that `status 404; erb :posts_not_found` returns 404 — not 200 — under the async route pipeline. |
| [`inertia-todo/`](inertia-todo/) | Sinatra + Inertia.js + Vue 3 | <https://inertia-todo.kazu-san.workers.dev/> | Server-rendered Inertia page object, `X-Inertia` content negotiation, JSON props. Client JS lives in `public/assets/inertia-app.js`. |
| [`hotwire-todo/`](hotwire-todo/) | Sinatra + Turbo Streams + Stimulus | <https://hotwire-todo.kazu-san.workers.dev/> | Server-rendered turbo-stream partials over `Accept: text/vnd.turbo-stream.html` negotiation. The only client JS is a tiny Stimulus controller for autofocus. |

## Running any example

Prerequisites: Ruby 3.4+, Node 20+, [`portless`](https://github.com/vercel-labs/portless)
(optional, for stable `*.localhost` URLs and avoiding port collisions
when several examples are running at once).

```bash
cd examples/<name>
bundle install
npm install
# D1-backed examples:
bundle exec rake db:migrate:local

bundle exec rake build      # opal compile + ERB precompile + asset embed
bundle exec rake dev        # wrangler dev (through portless if available)
```

Every example exposes the same Rake interface:

| Task | What it does |
|---|---|
| `rake build` | Run the full Workers build (Opal compile, ERB precompile, asset embed, auto-await rewrite). Output: `build/worker.entrypoint.mjs`. |
| `rake dev` | Start `wrangler dev --local` under `portless`, so the app is reachable at `http://<example-name>.localhost:1355/`. |
| `rake deploy` | `wrangler deploy` to your own Cloudflare account (set up `wrangler.toml` first). |
| `rake db:migrate:compile` *(D1 examples)* | Run `homura db:migrate:compile` to turn the Sequel migration DSL under `db/migrate/` into wrangler-compatible SQL. |
| `rake db:migrate:local` *(D1 examples)* | Compile, then `wrangler d1 migrations apply <db> --local`. |
| `rake db:migrate:remote` *(D1 examples)* | Compile, then `wrangler d1 migrations apply <db> --remote`. |

`auth-otp` has two extra tasks of its own — `rake mailpit:start` /
`rake mailpit:stop` for the mail sink, and `rake e2e` / `rake e2e:headed`
for the end-to-end flow. See [`auth-otp/README.md`](auth-otp/README.md).

## Shared conventions

The examples follow the same shape so they read like one another:

```
example/
├── Gemfile              # public gems only — opal-homura, homura-runtime,
│                        # sinatra-homura, (optionally sequel-d1)
├── Rakefile             # build / dev / deploy / db:migrate:*
├── config.ru            # require_relative 'app/app'; run App
├── package.json         # devDep: wrangler
├── wrangler.toml        # main = "build/worker.entrypoint.mjs"; bindings here
├── app/
│   └── app.rb           # Sinatra::Base subclass — your routes
├── views/               # *.erb (precompiled at build time)
├── public/              # static assets (embedded at build time)
└── db/migrate/          # *.rb Sequel migrations + compiled *.sql (D1 only)
```

`bundle exec rake build` populates a separate `build/` directory with
the generated `worker.entrypoint.mjs` plus its `cf-runtime/` glue;
`build/` is gitignored, so neither shows up in source control.

The Ruby in `app/` and `views/` is exactly the Ruby you'd write on
CRuby Sinatra. The build pipeline rewrites `__await__` calls,
precompiles ERB, and embeds `public/` at build time so the runtime
doesn't have to deal with the missing Workers filesystem.

## Why portless

Running several wrangler dev processes simultaneously means several TCP ports
to remember. [`portless`](https://github.com/vercel-labs/portless)
proxies them under stable subdomains (`http://todo.localhost:1355/`,
`http://blog.localhost:1355/`, …) so cookies, links, and screenshots
all stay valid no matter which port wrangler happened to bind. The
`Rakefile` in every example drives wrangler under portless when it is
installed; if it is not, replace `bundle exec rake dev` with a plain
`npx wrangler dev --local --port 8787` invocation.

## Hacking on these examples

Each example tracks its own `Gemfile.lock`, so a fresh `bundle install`
will pin you to exactly the gem versions the example was last verified
against. After changing Ruby code, `bundle exec rake build` rebuilds
`build/worker.entrypoint.mjs`; `wrangler dev` hot-reloads on the file change.

Open a browser at the printed URL, exercise the app, and watch the
local D1 file under `.wrangler/state/v3/d1/` if you want to see what
actually got persisted.
