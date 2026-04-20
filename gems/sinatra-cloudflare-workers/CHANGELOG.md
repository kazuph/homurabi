# Changelog

## 0.1.0 (2026-04-20)

- Initial extraction from homurabi (`sinatra_opal_patches`, `Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`).
- `require 'sinatra/cloudflare_workers'` loads runtime + patches + extensions + optional `run App` fallback.
- `cloudflare-workers-erb-compile` CLI (ERB → Ruby methods for Opal).
