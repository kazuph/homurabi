# Changelog

## 0.1.1 (2026-04-23)

- Fix `cloudflare-workers-build --standalone` and `exe/auto-await` to resolve the
  published gem names `homura-runtime` / `sinatra-homura`, while still accepting
  the legacy internal gem names as fallbacks.
- Add regression coverage for gem alias resolution and Gemfile path detection.

## 0.1.0 (2026-04-20)

- Initial extraction from homura as `homura-runtime` (Phase 15-B).
- Includes `cloudflare_workers`, `opal_patches`, and `runtime/{worker,setup-node-crypto}.mjs`.
