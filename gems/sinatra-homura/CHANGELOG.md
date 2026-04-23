# Changelog

## 0.1.1 (2026-04-23)

- Package the vendored Sinatra / Rack / Mustermann / JWT sources required for
  standalone Opal compilation inside the gem.
- Require `homura-runtime >= 0.1.2` so published standalone apps can resolve
  the runtime's packaged compile-time shims.

## 0.1.0 (2026-04-20)

- Initial extraction from homura (`sinatra_opal_patches`, `Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`).
- `require 'sinatra/cloudflare_workers'` loads runtime + patches + extensions + optional `run App` fallback.
- `cloudflare-workers-erb-compile` CLI (ERB → Ruby methods for Opal).
