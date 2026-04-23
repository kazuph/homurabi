# Changelog

## 0.1.1 (2026-04-23)

- Fix `cloudflare-workers-build --standalone` and `exe/auto-await` to resolve only
  the published gem names `homura-runtime` / `sinatra-homura`.
- Add regression coverage for gem name resolution and Gemfile path detection.

## 0.1.0 (2026-04-20)

- Initial extraction from homura as `homura-runtime` (Phase 15-B).
- Includes `cloudflare_workers`, `opal_patches`, and `runtime/{worker,setup-node-crypto}.mjs`.
