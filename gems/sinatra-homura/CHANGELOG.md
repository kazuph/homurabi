# Changelog

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
