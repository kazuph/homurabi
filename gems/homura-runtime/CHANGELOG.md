# Changelog

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
