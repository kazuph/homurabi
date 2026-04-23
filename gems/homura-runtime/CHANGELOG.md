# Changelog

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
