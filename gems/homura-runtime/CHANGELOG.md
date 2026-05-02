# Changelog

## 0.3.4 (2026-05-02)

- Package the Rack vendor files in `homura-runtime` itself. The 0.3.3
  release made Sinatra optional in the build path, but Rack-only apps
  still needed `rack/request` through `homura/runtime/multipart`; that
  worked from the monorepo checkout and failed from the published gem.

## 0.3.3 (2026-05-02)

- Make standalone Rack-only builds work without `sinatra-homura` in the
  bundle. `BuildSupport.standalone_load_paths` now treats Sinatra load
  paths as optional while keeping the existing Sinatra app path unchanged.
- Keep generated empty ERB registries Sinatra-free. Apps with no `.erb`
  templates no longer emit the Sinatra ERB hook, so a Rack-only app can
  compile with `homura-runtime` alone.
- Guard static-asset middleware auto-installation so the generated asset
  bundle only calls `Sinatra::Base.use` when a real Sinatra app is loaded.

## 0.3.2 (2026-04-30)

- README: replace the leftover `require 'cloudflare_workers'` line and
  the `gem 'opal-homura', '= 1.8.3.rc1.3'` pin with the canonical
  `require 'homura/runtime'` and `= 1.8.3.rc1.5` shipped on RubyGems.
- README support-matrix Opal row updated to `= 1.8.3.rc1.5` to match.
- No code changes vs. 0.3.1.

## 0.3.1 (2026-04-29)

- Fix `release-gems.yml` `Resolve gem target` step: now reads
  `gems/homura-runtime/lib/homura/runtime/version.rb` (was the
  pre-rename `gems/homura-runtime/lib/cloudflare_workers/version.rb`,
  which 0.3.0's tag-push publish failed on).
- No code changes since 0.3.0; this version exists only because
  re-tagging a published version is forbidden by the project's
  release rules. 0.3.0 was never published to RubyGems.

## 0.3.0 (2026-04-29) — BREAKING: cloudflare_workers naming eliminated

The "cloudflare_workers" branding everywhere inside the gem is gone.
gem name is `homura-runtime`, the module is now `HomuraRuntime`, the
require path is `require 'homura/runtime'`, and the Rack handler is
`Rack::Handler::Homura`. Apps that pinned ≤ 0.2.x and referenced
either `CloudflareWorkers::*` or `require 'cloudflare_workers'`
must update.

Renames:

| was | now |
|---|---|
| `module CloudflareWorkers` | `module HomuraRuntime` |
| `CloudflareWorkersIO` (stdout/stderr replacement class) | `HomuraRuntimeIO` |
| `Rack::Handler::CloudflareWorkers` | `Rack::Handler::Homura` |
| `require 'cloudflare_workers'` | `require 'homura/runtime'` |
| `lib/cloudflare_workers.rb` | `lib/homura/runtime.rb` |
| `lib/cloudflare_workers/*.rb` | `lib/homura/runtime/*.rb` |

`Cloudflare` namespace (binding wrappers like `Cloudflare::HTTP`,
`Cloudflare::D1Error`, `Cloudflare.js_promise?`) and Cloudflare-
specific Rack env keys (`env['cloudflare.DB']`, `env['cloudflare.KV']`,
…) are unchanged — those are factual descriptions of the underlying
Cloudflare Workers bindings, not branding.

No backward-compat shim. Per the project's `v1未満は破壊的に置き換え`
rule, old constant aliases are not preserved.

## 0.2.27 (2026-04-29)

- `Rack::Handler::CloudflareWorkers.run` now goes through
  `ensure_dispatcher_installed!` instead of duplicating the JS
  install snippet. Single source of truth for the dispatcher
  installation; `@dispatcher_installed` correctly tracks the state
  even when `run` is the first caller. Functionally identical from
  the user's point of view (dispatcher ends up in `globalThis`
  either way) — Copilot review on PR #34 spotted the duplication.

## 0.2.26 (2026-04-29)

- `Rack::Handler::CloudflareWorkers#call`: when `@app` is nil, fall
  back to `Sinatra::CloudflareWorkers.ensure_rack_app!` to discover
  the Sinatra app lazily on the first fetch. This is what lets
  classic-style apps omit the trailing `run Sinatra::Application`
  line (paired with `sinatra-homura >= 0.2.23`).
- New `Rack::Handler::CloudflareWorkers.ensure_dispatcher_installed!`:
  eagerly registers the JS-side dispatcher (`globalThis.__HOMURA_RACK_DISPATCH__`)
  at script-load time, so a fetch arriving before `run` was called
  still routes into our `call` method (where the lazy app discovery
  above kicks in). On Workers `at_exit` is unreliable because the
  isolate doesn't exit between requests; this eager install is the
  reliable hook.

## 0.2.25 (2026-04-29)

- `BuildSupport`: factor `opal_gem_paths` out of the path:-only
  `path_gemfile_entries`. The new method also picks up
  RubyGems-installed gems that opt in via
  `spec.metadata['homura.auto_await'] = 'true'`. Without this, a
  RubyGems-installed pure-Ruby gem (e.g. `sinatra-inertia >= 0.1.1`)
  was missing from both the Opal load path and the auto-await pass,
  so `require 'sinatra/inertia'` failed during `homura build`.
- `homura-build` iterates `opal_gem_paths` instead of the old
  path:-only list, so any opted-in gem (path: or RubyGems) gets the
  same auto-await rewrite.

## 0.2.24 (2026-04-29)

- `BuildSupport.standalone_load_paths`: auto-discover `path:`-resolved
  gems in the consumer Gemfile (skipping `require: false` and
  `group :development/:test/:ci/...` blocks) and add their `lib/` and
  `vendor/` to the Opal load path. Lets pure-Ruby gems like
  `sinatra-inertia` drop into a project without runtime-side wiring.
- `homura-build` now runs the `auto-await` analyzer over each `path:`
  gem's `lib/` and writes the rewritten copy under
  `build/auto_await/gem_<basename>/lib`. The transformed directory
  is preferred over the gem's untransformed `lib/` on the load path,
  so async chains inside gem code (e.g. `db[:foo].all` returning a
  Promise) get `__await__` injected exactly like consumer app code.
- `cloudflare_workers.rb#build_js_response`: emit `Set-Cookie`
  Arrays via `Headers#append` (multiple lines) instead of stringifying
  the Array via `to_s`. Previously, two cookies set by sequential Rack
  middleware (e.g. session + auth) were serialised as
  `'["a=…", "b=…"]'`, which broke cookie parsing on every Inertia /
  CSRF / auth-cookie pattern.

## 0.2.17 (2026-04-27)

- Rewrite class-variable references (`@@foo`) inside precompiled ERB
  templates into explicit `class_variable_get` / `class_variable_set`
  calls on the instance's class. Opal evaluates compiled template
  bodies via `instance_exec` on a Sinatra instance whose `$$cvars`
  slot is undefined at that runtime path, so the previous build emit
  blew up with `TypeError: Cannot read properties of undefined (reading
  '$$cvars')` whenever a template touched `<%= @@todos %>` or
  `<% @@todos.each ... %>` directly. Templates can now use the
  natural Sinatra style (`@@cvar` reads, `@@cvar = expr` and compound
  `@@cvar op= expr` assignments) without route-level `@todos = @@todos`
  shims. Fixes #28.

## 0.2.11 (2026-04-25)

- Normalize bare JS `undefined` / `null` values to Ruby `nil` while converting
  D1 rows into Ruby Hashes, preventing first-row crashes when a nullable column
  is present in the result shape.

## 0.2.10 (2026-04-24)

- Derive `build/worker.entrypoint.mjs` import paths relative to the actual
  `--entrypoint-out` location, so standalone builds keep working when apps move
  the bundle and entrypoint under custom output directories.

## 0.2.9 (2026-04-24)

- Skip auto-await rewrites when the source expression is already followed by
  `.__await__`, avoiding noisy double-application in rewritten standalone app
  code.

## 0.2.8 (2026-04-24)

- Compile standalone `config.ru` inputs from `build/auto_await/` so ordinary
  `require_relative 'app/app'` entrypoints pick up the auto-awaited app copy
  instead of silently falling back to the original source.
- Teach the auto-await analyzer to prefer locally inferred helper return types
  over generic registry defaults, and infer memoized `foo ||= ...` helper bodies.
- Preserve redirect headers when awaited routes resolve to Rack tuples through
  the Promise response builder.
- Add `layout.erb` by default in the precompiled ERB runtime so `erb :index`
  behaves like ordinary Sinatra unless the app passes `layout: false`.

## 0.2.7 (2026-04-24)

- Auto-detect standalone app entrypoints from `config.ru`, `app/hello.rb`, then
  `app/app.rb`, and accept `config.ru` inputs by compiling a temporary Ruby copy
  under the hood.
- Add the project root to standalone Opal load paths so standard
  `require_relative 'app/app'` config.ru setups compile without extra wrappers.
- Synthesize `HTTP_HOST` from the request URL inside the Rack env so absolute
  redirects preserve the current host and non-default port in local dev.

## 0.2.6 (2026-04-24)

- Remove the shipped `cloudflare-workers-build` filename entirely and keep the
  build implementation under `exe/homura-build`, matching the `homura build`
  public surface.
- Make `homura build --with-db` imply the consumer-safe standalone path so D1 /
  Sequel apps do not need to remember both flags.
- Let `compile-assets` succeed for an empty `public/` directory and improve the
  auto-await analyzer so async local helper methods are awaited at their call
  sites.

## 0.2.5 (2026-04-23)

- Load Workers-only `zlib`, `tempfile`, and `tilt` shims via `require_relative`
  so plain `opal` CLI builds can require `opal_patches` without extra vendor
  load path wiring.
- Recursively convert nested plain JS objects in `Cloudflare.js_object_to_hash`
  so D1 metadata behaves like Ruby `Hash` values all the way down.
- Pin `opal-homura` to `1.8.3.rc1.3` for the restored `digest` stdlib shim.

## 0.2.4 (2026-04-23)

- Guard the Rack body close hook against raw JS `undefined` so Workers request teardown
  does not crash when a response body is absent or non-Ruby.

## 0.2.3 (2026-04-23)

- Bump the exact `opal-homura` dependency to `1.8.3.rc1.2` for the release retry after the
  previous tag push failed to trigger RubyGems publication.
- Preserve async Sinatra responses that resolve to `[status, body]` or `[status, headers, body]`
  so `# await: true` routes can still express `halt` / `redirect` outcomes after awaiting.

## 0.2.1 (2026-04-23)

- Correct the published author metadata to "Kazuhiro Homma".

## 0.2.0 (2026-04-23)

- Remove the old standalone build executable and expose the
  build pipeline through `homura build`.
- Keep the internal build implementation in the runtime gem while letting the
  single `homura` CLI dispatch to it.

## 0.1.6 (2026-04-23)

- Teach `homura build --standalone --with-db` to add the packaged
  `sequel-d1` gem `vendor/` directory to the Opal load path before the gem's
  `lib/`, so `require 'sequel'` resolves to the bundled Opal-compatible Sequel
  subset instead of the CRuby gem.

## 0.1.5 (2026-04-23)

- Make `auto-await` emit rewritten files for existing hand-written `.__await__`
  usage when the only missing piece is `# await: true`.
- Make `homura build --standalone` restore `cf-runtime/` from the
  packaged gem and derive standalone template/asset namespaces from the project
  name by default, with explicit override flags when needed.
- Reject unsupported ERB yield forms like `<% yield %>` and `yield(arg)` with
  compile-time guidance toward the supported Sinatra-style layout forms.

## 0.1.4 (2026-04-23)

- Teach the precompiled ERB runtime to support Sinatra-style layout blocks and
  `<%= yield %>` in layout templates.
- Keep legacy `@content` / `@docs_inner` layouts working as compatibility
  fallbacks while apps migrate to the least-surprise Sinatra style.

## 0.1.3 (2026-04-23)

- Fix binary static asset embedding so image responses preserve exact bytes on
  Workers instead of being mangled through text encoding.
- Add regression coverage for binary-vs-text compile-assets output.
- Convert shipped mascot/icon assets to real PNG payloads so their bytes match
  their `.png` filenames and `image/png` content type.

## 0.1.2 (2026-04-23)

- Package the runtime's Opal compile-time vendor shims (`digest`, `zlib`,
  `tempfile`, `tilt`, `rubygems/version`) inside the gem.
- Teach `homura build --standalone` to add packaged gem `vendor/`
  directories to the Opal load path, so published gems no longer depend on the
  monorepo root `vendor/`.
## 0.1.1 (2026-04-23)

- Fix `homura build --standalone` and `exe/auto-await` to resolve only
  the published gem names `homura-runtime` / `sinatra-homura`.
- Add regression coverage for gem name resolution and Gemfile path detection.

## 0.1.0 (2026-04-20)

- Initial extraction from homura as `homura-runtime` (Phase 15-B).
- Includes `cloudflare_workers`, `opal_patches`, and `runtime/{worker,setup-node-crypto}.mjs`.
