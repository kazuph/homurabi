# Changelog

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
