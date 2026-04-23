# Changelog

## 0.2.0 (2026-04-23)

- Remove the old `cloudflare-workers-build` public executable and expose the
  build pipeline through `homura build`.
- Keep the internal build implementation in the runtime gem while letting the
  single `homura` CLI dispatch to it.

## 0.1.6 (2026-04-23)

- Teach `cloudflare-workers-build --standalone --with-db` to add the packaged
  `sequel-d1` gem `vendor/` directory to the Opal load path before the gem's
  `lib/`, so `require 'sequel'` resolves to the bundled Opal-compatible Sequel
  subset instead of the CRuby gem.

## 0.1.5 (2026-04-23)

- Make `auto-await` emit rewritten files for existing hand-written `.__await__`
  usage when the only missing piece is `# await: true`.
- Make `cloudflare-workers-build --standalone` restore `cf-runtime/` from the
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
- Teach `cloudflare-workers-build --standalone` to add packaged gem `vendor/`
  directories to the Opal load path, so published gems no longer depend on the
  monorepo root `vendor/`.
## 0.1.1 (2026-04-23)

- Fix `cloudflare-workers-build --standalone` and `exe/auto-await` to resolve only
  the published gem names `homura-runtime` / `sinatra-homura`.
- Add regression coverage for gem name resolution and Gemfile path detection.

## 0.1.0 (2026-04-20)

- Initial extraction from homura as `homura-runtime` (Phase 15-B).
- Includes `cloudflare_workers`, `opal_patches`, and `runtime/{worker,setup-node-crypto}.mjs`.
