# Changelog

## 0.2.23 (2026-04-29)

- The canonical sinatrarb.com snippet now works verbatim on Workers.
  Previously, even after 0.2.22 made `require 'sinatra'` enough to load
  the runtime, users still had to write `run Sinatra::Application` /
  `run App` themselves because `ensure_rack_app!` only handled
  `class App < Sinatra::Base` (and only at_exit-fired when
  `sinatra/cloudflare_workers` was required directly). Two changes
  fix this:

  - `vendor/sinatra.rb` and `vendor/sinatra/base.rb` now require
    `sinatra/cloudflare_workers` (was just `cloudflare_workers`), so
    the at_exit hook is installed by `require 'sinatra'` /
    `require 'sinatra/base'` alone.
  - `Sinatra::CloudflareWorkers.ensure_rack_app!` now also detects
    classic-style `Sinatra::Application` (top-level `get '/' do … end`)
    and registers it with `Rack::Handler::CloudflareWorkers` if it has
    routes. Modular `App` still wins when both are defined.

  Net effect: this app:

  ```ruby
  require 'sinatra'
  get '/frank-says' do
    'Put this in your pipe & smoke it!'
  end
  ```

  …and this app:

  ```ruby
  require 'sinatra/base'
  class App < Sinatra::Base
    get '/' do; 'hi'; end
  end
  ```

  …both now run on Workers without an extra
  `require 'sinatra/cloudflare_workers'` line and without a trailing
  `run Sinatra::Application` / `run App` line. Existing apps with
  either of those lines still work; the require is a no-op second load
  and `run` still wins over the at_exit auto-registration.

- Bumps `homura-runtime` floor to `>= 0.2.25` (Set-Cookie Array fix
  + path:/RubyGems gem auto-await pipeline) so Inertia / CSRF
  middleware patterns light up out of the box.

## 0.2.17 (2026-04-27)

- Preserve `content_type`, `headers`, and `status` set inside async / `await: true`
  routes. The Cloudflare Workers Rack handler snapshots the response triple
  before awaiting the body promise, so any `content_type 'application/json'` or
  `status 404` mutation that lands AFTER the route block returned its Promise
  was silently dropped (final response defaulted to `text/html`, status 200).
  `route_eval` now wraps the Promise so it resolves to a fully-materialized
  `[response.status, response.headers, [body]]` triple, which the handler's
  existing "first element is Integer" branch picks up unchanged.
- Patch `Rack::Utils.parse_cookies_header` to decode cookie values with
  `decodeURIComponent` semantics. Opal's `URI.encode_www_form_component` does
  not escape `+`, so cookie values containing a literal `+` (e.g.
  `demo+foo@example.com`) were round-tripping as `demo foo@example.com`
  because the read path went through the form-encoded `+`-to-space mapping.

## 0.2.16 (2026-04-25)

- Internal alignment with the homura-runtime 0.2.13 release set.

## 0.2.15 (2026-04-24)

- Align gem dependencies with the new release set (homura-runtime / opal-homura
  bumps).

## 0.2.14 (2026-04-24)

- Scaffold `--with-db` apps with a first-class D1 migration flow: a starter
  `db/migrate/` file, `rake db:migrate:{compile,local,remote}` tasks, matching
  package.json scripts, and a `[[d1_databases]]` wrangler block.
- Rely on `homura-runtime >= 0.2.10` so generated apps inherit the standalone
  entrypoint-relative import fix.

## 0.2.13 (2026-04-24)

- Add `rake` to generated app Gemfiles so the scaffolded `bundle exec rake
  build|dev|deploy` workflow works under Bundler out of the box.
- Rely on `homura-runtime >= 0.2.9` so fresh apps pick up the auto-await
  double-application fix.

## 0.2.12 (2026-04-24)

- Raise a materialized `HaltResponse` directly from `redirect`, keeping awaited
  Sequel/D1 routes on the normal Sinatra 302/303 path instead of degrading to
  `200 []`.
- Rely on `homura-runtime >= 0.2.8` so standalone `config.ru` builds, default
  ERB layouts, and awaited redirect tuple headers stay aligned.

## 0.2.11 (2026-04-24)

- Preserve non-default ports when Sinatra builds absolute redirect locations in
  standalone / local-dev flows.
- Scaffold apps with standard `config.ru` + `app/app.rb`, and stop requiring an
  `app/hello.rb` wrapper in freshly generated projects.
- Require `homura-runtime >= 0.2.7` so scaffolded `config.ru` entrypoints and
  standalone build detection stay aligned.

## 0.2.10 (2026-04-24)

- Preserve `params['id']` and other route params across async / awaited routes
  in standalone-built Sinatra apps.
- Scaffold `--with-db` apps so their generated build task passes
  `--standalone --with-db` by default.
- Require `homura-runtime >= 0.2.6` so the `homura build` dispatch target and
  standalone DB build defaults stay aligned.

## 0.2.9 (2026-04-23)

- Pin `opal-homura` to `1.8.3.rc1.3` so apps using `sinatra-homura`,
  `homura-runtime`, and `sequel-d1` resolve the same restored `digest`
  stdlib shim release.

## 0.2.8 (2026-04-23)

- Keep `wrap_async_halt_result`'s Promise `.catch(...)` wrapper as a real
  expression so Opal returns the wrapped Promise instead of `undefined`,
  fixing empty bodies for `# await: true` Sinatra routes that awaited D1 /
  native JS Promises under `wrangler dev`.

## 0.2.7 (2026-04-23)

- Guard `apply_invoke_result` against raw JS `undefined` and prioritize
  Promise handling before `respond_to?(:each)`, fixing the remaining
  `$respond_to?` crash path seen by real `# await: true` apps under
  `wrangler dev`.

## 0.2.6 (2026-04-23)

- Guard nested param values against raw JS `undefined` during `force_encoding`,
  fixing the remaining `dispatch!` / `$respond_to?` crash under `wrangler dev`.

## 0.2.5 (2026-04-23)

- Make `Sinatra::Base#dispatch!` skip raw JS `undefined` param values before calling
  `respond_to?`, fixing `# await: true` apps that crashed during request dispatch under
  `wrangler dev`.

## 0.2.4 (2026-04-23)

- Bump the exact `opal-homura` dependency to `1.8.3.rc1.2` for the release retry after the
  previous tag push failed to trigger RubyGems publication.
- Make explicit `halt` work across Opal async boundaries by carrying a materialized Rack tuple
  through awaited routes, which also restores conventional async `redirect` behavior.
- Add worker-path regression coverage for `params['id']`, async `redirect`, and async `halt`.

## 0.2.2 (2026-04-23)

- Correct the published author metadata to "Kazuhiro Homma".

## 0.2.1 (2026-04-23)

- Make generated apps Rake-first: the scaffolded `Rakefile` now owns build/dev/deploy,
  and scaffolded `package.json` delegates back to Rake instead of exposing `homura`
  directly as the main user workflow.

## 0.2.0 (2026-04-23)

- Make `homura` the only public executable and add subcommands for build, ERB
  precompile, migrations, and scaffolding.
- Remove the old `cloudflare-workers-*` compatibility entrypoints instead of
  carrying aliases before v1.

## 0.1.3 (2026-04-23)

- Add the preferred `homura new` scaffold entrypoint while keeping
  `cloudflare-workers-new` as a compatibility alias.
- Match runtime-side ERB diagnostics so unsupported yield forms fail at compile
  time with guidance toward `<%= yield %>` / `<%== yield %>`.
- Require `homura-runtime >= 0.1.5` so standalone build/runtime behavior stays
  aligned.

## 0.1.2 (2026-04-23)

- Make `cloudflare-workers-erb-compile` support Sinatra-style layout blocks and
  `<%= yield %>` in precompiled layouts.
- Require `homura-runtime >= 0.1.4` so runtime and app-side ERB compilers stay
  in sync on the same least-surprise layout behavior.

## 0.1.1 (2026-04-23)

- Package the vendored Sinatra / Rack / Mustermann / JWT sources required for
  standalone Opal compilation inside the gem.
- Require `homura-runtime >= 0.1.2` so published standalone apps can resolve
  the runtime's packaged compile-time shims.

## 0.1.0 (2026-04-20)

- Initial extraction from homura (`sinatra_opal_patches`, `Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`).
- `require 'sinatra/cloudflare_workers'` loads runtime + patches + extensions + optional `run App` fallback.
- `cloudflare-workers-erb-compile` CLI (ERB → Ruby methods for Opal).
