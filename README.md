<p align="center">
  <img src="public/homura-chan.png" alt="homura mascot" width="200">
</p>

# homura

**A platform for running real Ruby applications on Cloudflare Workers.**

Live site: <https://homura.kazu-san.workers.dev>

```ruby
# app/app.rb — yes, it really is plain Sinatra.
require 'sinatra/cloudflare_workers'

class App < Sinatra::Base
  get '/' do
    'Hello from Ruby, running on Cloudflare Workers.'
  end

  get '/users' do
    db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    content_type :json
    db[:users].order(:id).all.to_json
  end
end

run App
```

```toml
# wrangler.toml — exactly what Cloudflare expects.
name = "myapp"
main = "worker.entrypoint.mjs"
compatibility_date = "2026-04-27"
compatibility_flags = ["nodejs_compat"]
```

There is no shim, no transpiled Sinatra-lookalike. The `Sinatra::Base` you
inherit from is a port of the upstream gem; `redirect '/'` raises Sinatra's
own `HaltResponse`; `erb :index, locals: { user: u }` resolves locals the
way the docs say it does. The whole pipeline exists so Ruby people can keep
writing Ruby and ship it to the Cloudflare edge.

---

## Why homura

Cloudflare Workers does not run a Ruby VM. It runs JavaScript on V8, with
no filesystem, no `eval`-from-string, no native extensions. The standard
Ruby stack — Sinatra, Sequel, `SecureRandom`, ERB — assumes all of those.

homura is the glue that closes that gap:

- **Real Sinatra DSL** — `get`, `post`, `before`, `after`, `helpers`, `halt`,
  `redirect`, `erb` with `locals:` and layout, `Sinatra::Base` inheritance
  exactly as upstream documents.
- **Edge SQL** — `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`
  works against Cloudflare D1; migrations are written in Sequel DSL and
  compiled to wrangler-compatible SQL. Or skip the ORM and use the
  `Cloudflare::D1Database` wrapper directly.
- **All the bindings** — D1, KV, R2, Workers AI, Queues, Scheduled, Durable
  Objects, Vectorize. They surface as ordinary Ruby objects in
  `request.env['cloudflare.<NAME>']`.
- **Ordinary distribution** — four gems on RubyGems. No `path:`,
  no submodules, no clone of homura required.
- **Async without ceremony** — the build step rewrites the `__await__`
  calls Workers needs into the obvious sync-looking source you'd write on
  CRuby. `db.execute(...)` reads like sqlite3-ruby, not like a coroutine.

If a stock Sinatra-on-Workers idiom doesn't behave the way Ruby developers
expect, that is a bug in homura, not a quirk of the stack. The
[examples/](examples/) directory is the contract.

---

## How it works

```
                         CRuby (build host)               Cloudflare Workers (V8)
                ┌────────────────────────────────┐        ┌──────────────────────────┐
 your Ruby ───► │  bundle exec rake build         │ ─────► │   worker.entrypoint.mjs  │
 your views ───►│   ├─ Opal compile (Ruby → JS)   │        │   (loaded by wrangler)   │
 your migrate ─►│   ├─ ERB precompile             │        │   ├─ homura runtime      │
                │   ├─ public/ asset embed        │        │   ├─ your compiled app   │
                │   └─ auto-await pass            │        │   └─ binding shims       │
                └────────────────────────────────┘        └──────────────────────────┘
```

Four gems own the work:

| Gem | Responsibility |
|---|---|
| [`opal-homura`](https://rubygems.org/gems/opal-homura) | Patched Opal compiler — turns Ruby into the JavaScript that V8 runs. Keep `require: 'opal'`. |
| [`homura-runtime`](https://rubygems.org/gems/homura-runtime) | Worker entrypoint, Rack adapter, Cloudflare binding wrappers (D1/KV/R2/AI/Queue), build pipeline (`homura build`). |
| [`sinatra-homura`](https://rubygems.org/gems/sinatra-homura) | Sinatra port + Opal-compatibility patches, scaffolder (`homura new`), JWT / Scheduled / Queue helpers, ERB precompiler. |
| [`sequel-d1`](https://rubygems.org/gems/sequel-d1) | Sequel adapter for Cloudflare D1, migration compiler (`homura db:migrate:*`). |

The build output is a **single `worker.entrypoint.mjs`** plus the embedded
asset bundle. `wrangler deploy` ships that file straight to the edge.

---

## Quick start: a new project

Prerequisites: Ruby 3.4+, Node 20+, `wrangler` (or just `npx wrangler`).

```bash
# Install the scaffolder.
gem install sinatra-homura

# Generate a project (add --with-db for D1 + Sequel).
homura new myapp
cd myapp

# Install dependencies.
bundle install
npm install

# Build the Worker bundle.
bundle exec rake build

# Run wrangler dev locally.
bundle exec rake dev
# → http://127.0.0.1:8787
```

`homura new --with-db myapp` additionally writes a Sequel migration under
`db/migrate/`, declares a D1 binding in `wrangler.toml`, and adds
`db:migrate:compile`, `db:migrate:local`, and `db:migrate:remote` Rake
tasks. The local development cycle is:

```bash
bundle exec rake db:migrate:local   # apply migrations to local D1 (sqlite shim)
bundle exec rake build              # rebuild after editing Ruby
bundle exec rake dev                # wrangler dev, hot-reloads on rebuild
```

Production deploy:

```bash
npx wrangler d1 create myapp                       # one-time
# paste the new database_id into wrangler.toml
bundle exec rake db:migrate:remote                 # apply to remote D1
bundle exec rake deploy                            # wrangler deploy
```

---

## Adding homura to an existing project

If you already have Ruby and want to ship it to Workers:

1. **Pin the four gems** in your `Gemfile`:

   ```ruby
   source 'https://rubygems.org'
   ruby '>= 3.4.0'

   gem 'rake'
   gem 'opal-homura',    '= 1.8.3.rc1.5', require: 'opal'
   gem 'homura-runtime', '~> 0.2'
   gem 'sinatra-homura', '~> 0.2'
   gem 'sequel-d1',      '~> 0.2'   # only if you want D1 / Sequel
   ```

2. **Move app code under `app/`** (`app/app.rb` is the conventional
   entrypoint). Keep your routes; replace `require 'sinatra'` with
   `require 'sinatra/cloudflare_workers'`. Subclass `Sinatra::Base`.

3. **Add `wrangler.toml`** pointing `main` at `worker.entrypoint.mjs` and
   declaring the bindings you need (D1 / KV / R2 / AI / Queue).

4. **Build and run** with `bundle exec rake build && bundle exec rake dev`.

For an existing classic-style Sinatra app, the smallest path is to copy
`examples/classic-top-sinatra/` and merge your routes in. For a
modular-style app, start from `examples/todo/` (no ORM) or
`examples/todo-orm/` (Sequel + D1).

The [Workers gotchas](#known-gotchas-and-where-they-are-handled) section
below lists the small set of places where the Workers runtime forces a
divergence from CRuby.

---

## Examples

[`examples/`](examples/) contains six fully-working applications, each one
a standalone project that depends on the published gems only — no
`path:` references back to the monorepo. They are also the regression
fixtures behind the latest gem releases.

| Example | What it shows |
|---|---|
| [`todo-simple`](examples/todo-simple/) | **The smallest example.** One `app.rb`, no `views/` directory, no D1 — HTML written as Ruby heredocs. The thing to copy when "how little does homura need" is the question. |
| [`todo`](examples/todo/) | D1-backed CRUD without an ORM — `env['cloudflare.DB']` and `Cloudflare::D1Database` directly. |
| [`todo-orm`](examples/todo-orm/) | The same TODO app, this time through `sequel-d1`: migrations, dataset chains, `.first` / `.update`. |
| [`auth-otp`](examples/auth-otp/) | Email OTP login. Sends through [mailpit](https://mailpit.axllent.org/) in development; HMAC-signed session cookie; full headed Playwright E2E in `rake e2e:headed`. |
| [`blog`](examples/blog/) | A small blog: index / detail / new / **proper 404** / delete. Demonstrates async-route status preservation and `<%= h(post[:body]).gsub("\n", "<br>") %>`. |
| [`inertia-todo`](examples/inertia-todo/) | A thin SPA via [Inertia.js](https://inertiajs.com) + Vue 3, with Sinatra serving page props. Client-side JS lives in `public/assets/`. |
| [`hotwire-todo`](examples/hotwire-todo/) | Turbo Streams (server-rendered partials over Accept negotiation) + a tiny Stimulus controller for autofocus. |

There are also smaller historical fixtures under
[`examples/minimal-sinatra*`](examples/) — they predate the public-gem
rewrite and use `path:` references back to this monorepo. Use them as
internal smoke tests, not as templates.

See [`examples/README.md`](examples/README.md) for the full index with
URLs and per-app feature notes.

---

## Known gotchas (and where they are handled)

The Workers runtime forces a few real divergences from CRuby. homura
absorbs each of them in the gem layer so application code does not have
to:

- **No `String#<<`.** Opal Strings are JS strings, so any code that builds
  output through mutation (`host = String.new; host << '...'`) breaks.
  `sinatra-homura` rebuilds `Sinatra::Helpers#uri` / `redirect` /
  `content_type` with `+`-style concatenation, so `redirect to('/')`
  works the way Sinatra docs say.
- **No `binding.eval`.** Workers blocks `new Function(string)`, which ERB
  uses for template rendering. `homura-runtime` precompiles every
  `views/*.erb` to a Ruby method at build time and dispatches `erb :name`
  there. `erb :_partial, locals: { t: t }` resolves bare `t` via a
  template-locals stack + `Sinatra::Base#method_missing`.
- **No filesystem.** `public/` is bundled at build time and served from
  memory by a Rack middleware homura installs.
- **`String == Symbol` under Opal.** `Sequel::LiteralString` was being
  caught by Sequel's `case v when Symbol` branch and emitted as a
  backtick-quoted identifier. `sequel-d1` reorders the `literal_append`
  branches so `update(done: Sequel.lit('1 - done'))` lands in
  `literal_literal_string_append`.
- **Async at the edge.** D1 / KV / fetch are all promise-shaped. The
  build pipeline runs an auto-await pass that inserts `__await__` for
  registered async methods (`db.execute`, `kv.get`, `Cloudflare::AI.run`,
  …), so route bodies stay sync-shaped.

If you find an idiom that should "just work" but does not, it belongs on
this list. File an issue.

---

## AI / agent support

homura ships agent-discoverable docs so Claude / Copilot / Cursor can
pick the right gem and follow the canonical install/build flow without a
human in the loop.

- **Machine-readable summary**: [`/llms.txt`](public/llms.txt) — also
  served live at <https://homura.kazu-san.workers.dev/llms.txt>.
- **Long-form docs**: <https://homura.kazu-san.workers.dev/docs>
  (renderable from this repo's `docs/`).
- **Installable agent skill**: [`skills/homura-workers-gems/`](skills/homura-workers-gems/)
  — a packaged Claude / Copilot skill that teaches an agent which gem to
  pick, the minimal `homura new` flow, and the recurring Workers/Opal
  gotchas.

Install the skill:

```bash
# GitHub Copilot (or any host that reads `gh skill`)
gh skill install kazuph/homura homura-workers-gems --agent github-copilot --scope user

# Claude Code (project-scoped is recommended)
gh skill install kazuph/homura homura-workers-gems --agent claude-code --scope project

# npm-based installer (also works for Claude / Copilot)
npx skills add kazuph/homura --skill homura-workers-gems -a claude-code
```

---

## Repository layout

```
gems/                 # The four published gems live here
  homura-runtime/     # core runtime + build pipeline
  sinatra-homura/     # Sinatra port + Opal patches + scaffolder
  sequel-d1/          # Sequel D1 adapter + migration compiler
vendor/opal-gem/      # Source of opal-homura (the patched Opal fork)
examples/             # Six standalone example apps (see above)
docs/                 # Long-form documentation
public/llms.txt       # Agent-readable summary
skills/               # Installable agent skills
```

The `gems/*` directories and `vendor/opal-gem/` are the shipping surface.
Everything else is either documentation, examples, or the infrastructure
that builds and ships those four gems.

---

## License

MIT. See [`LICENSE`](LICENSE).
