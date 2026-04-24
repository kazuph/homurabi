# Gotchas

## Published names vs old internal names

Prefer:

- `homura-runtime`
- `sinatra-homura`
- `sequel-d1`
- `opal-homura`

Do not introduce the old names in fresh guidance unless explicitly explaining history.

## Async Sinatra routes

In this repo's Opal-on-Workers runtime:

- current releases support ordinary Sinatra `redirect` / `halt` across async
  boundaries
- explicit Rack tuples such as `[status, body]` and `[status, headers, body]`
  also work in async routes
- if a downstream app still shows empty bodies or broken redirects, verify it is
  actually using the latest published gems before changing app code

## D1 / Sequel

- `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`
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

## Layout rendering

- `<%= yield %>` in precompiled layout templates is supported
- `@content = erb :index; erb :layout` is legacy compatibility, not the preferred
  shape for fresh examples
- prefer Sinatra-style `erb :index, layout: :layout`

## Build output

- the Worker entrypoint is `build/worker.entrypoint.mjs`
- `bundle exec homura build` is the standard build command
- Sequel/D1 standalone apps should use `bundle exec homura build --standalone --with-db`
- but generated apps should expose `bundle exec rake build|dev|deploy` as the normal user workflow
- `compile-assets` now tolerates an empty `public/` directory; static files are optional
- if Opal compile fails, inspect `build/opal.stderr.log`

## Wrangler compatibility date

- `compatibility_date` must not be in the future relative to the local machine
  date; `wrangler dev` rejects future dates

## Existing app migration

- do not over-automate full legacy app migration with one-shot commands
- for existing apps, move backend/API boundaries first and keep full SSR migration as a separate decision
- add a Rake wrapper layer early so Ruby developers keep interacting with Rake instead of low-level platform commands

## Bundler / RubyGems compact index mismatch

`homura-runtime 0.1.0` was published with a runtime dependency on
`opal-homura (= 1.8.3.rc1)`, but RubyGems compact index metadata can omit that
dependency for this version. When that happens, Bundler may fail with:

- `Downloading homura-runtime-0.1.0 revealed dependencies not in the API`

Practical guidance:

- for local installs, prefer `bundle install --full-index` when this error appears
- clearing Bundler cache alone does not fix it if the upstream compact index is wrong
- keeping `gem 'opal-homura', '= 1.8.3.rc1', require: 'opal'` explicit in the
  Gemfile is still recommended

Publisher-side guidance:

- do not treat this as a user-only problem; verify published metadata after each
  release with both the `.gemspec.rz` payload and `https://rubygems.org/info/<gem>`
- if compact index metadata is wrong, publish a new patch release and verify the
  new index entry before telling users to retry
- if RubyGems still serves stale or incomplete index data for the new release,
  escalate to RubyGems support/maintainers because cache clears on the client
  side will not repair server-side metadata

## Bindings

Bindings are exposed in Rack env under keys like:

- `env['cloudflare.DB']`
- `env['cloudflare.KV']`
- `env['cloudflare.BUCKET']`
- `env['cloudflare.AI']`

Use those names in examples instead of inventing new wrapper APIs.
