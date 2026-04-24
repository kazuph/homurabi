# Gotchas

## Command surface

- Use `homura` and generated `rake` tasks.
- Do not emit any `cloudflare-workers-*` command names in fresh guidance.
- Generated apps should feel Rake-first: `bundle exec rake dev|build|deploy`.
- For `--with-db` scaffolds, also expose `bundle exec rake db:migrate:compile|local|remote`.

## Async Sinatra routes

In this repo's Opal-on-Workers runtime:

- current releases support ordinary Sinatra `redirect` / `halt` across async boundaries
- explicit Rack tuples such as `[status, body]` and `[status, headers, body]`
  also work in async routes
- `params['id']` should survive across async route bodies in current releases
- if a downstream app still shows empty bodies or broken redirects, verify it is
  actually using the latest published gems before changing app code

## D1 / Sequel

- `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`
- Treat `require 'sequel'` as the public require path. Do not teach `require 'sequel/d1'`.
- `Dataset#all` still resolves asynchronously under the hood, but common
  Sinatra-facing call sites are auto-awaited at build time, so examples should
  usually stay sync-shaped (`db[:users].all`, not `db[:users].all.__await__`)
- current releases also support Sequel write DSL on D1 (`insert`, `update`,
  `delete`) without dropping to raw D1 bindings
- keep manual `.__await__` for raw Promise work or patterns the auto-await
  registry does not recognize yet
- helper methods in the same file can also become async through auto-await
  propagation, but dynamic metaprogramming still may need manual `.__await__`
- simple-table D1 / SQLite boolean columns now coerce back to Ruby booleans on
  normal dataset reads (`db[:todos].all`, `first`, etc.)
- custom SQL / custom projections that lose schema context can still surface raw
  `0` / `1`, so be explicit there if needed
- current releases support Sequel write DSL on D1 (`insert`, `update`, `delete`)
  without dropping to raw D1 bindings

## Layout rendering

- `<%= yield %>` in precompiled layout templates is supported
- prefer Sinatra-style `erb :index, layout: :layout`

## Build output

- generated apps write the Worker entrypoint to `worker.entrypoint.mjs`
- monorepo / internal builds still write `build/worker.entrypoint.mjs`
- `bundle exec homura build` is the standard build command
- default entrypoint discovery prefers `config.ru`, then `app/hello.rb`, then `app/app.rb`
- Sequel/D1 standalone apps should use `bundle exec homura build --standalone --with-db`
- generated apps should expose `bundle exec rake build|dev|deploy` as the normal user workflow
- if you override `--output` or `--entrypoint-out`, homura now rewrites import paths relative to the actual entrypoint location
- `compile-assets` now tolerates an empty `public/` directory; static files are optional
- if Opal compile fails, inspect `build/opal.stderr.log`
- standard Sinatra `config.ru` with `run App` is supported in current releases

## Wrangler compatibility date

- `compatibility_date` must not be in the future relative to the local machine
  date; `wrangler dev` rejects future dates
- `nodejs_compat` is required in generated / documented apps because the runtime depends on `node:crypto`

## Bindings

Bindings are exposed in Rack env under keys like:

- `env['cloudflare.DB']`
- `env['cloudflare.KV']`
- `env['cloudflare.BUCKET']`
- `env['cloudflare.AI']`

Use those names in examples instead of inventing new wrapper APIs.
