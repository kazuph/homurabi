# Vendor patch inventory (Phase 15-A)

**Scope**: catalogue in-repo modifications under `vendor/` (no new edits in
this phase). Goal: Phase 15-D migration — each hunk should eventually move to
(a) `lib/` monkey patches, (b) upstream PRs, or (c) stay vendored with a
written retention reason.

## Summary table

| Area | Files (representative) | Why vendored / patched |
|------|------------------------|-------------------------|
| **Sequel** | `vendor/sequel.rb`, `vendor/sequel/core.rb`, `vendor/sequel/database/connecting.rb`, `vendor/sequel/dataset/{sql,query,actions}.rb`, `vendor/sequel/sql.rb`, `vendor/sequel/connection_pool.rb`, `vendor/sequel/timezones.rb` | Opal lacks `thread`, mutable strings, and `class_eval(String)` on Workers; Phase 12 replaced dynamic SQL generation with `define_method` / small parsers; eager adapter registration. **Retention**: core ORM path depends on these semantics until an upstream `opal-sequel` strategy exists. |
| **Sinatra** | `vendor/sinatra.rb`, `vendor/sinatra/base.rb`, `vendor/sinatra/show_exceptions.rb` | Loader selects `sinatra_upstream`; `show_exceptions` stubbed to avoid pulling `rack/show_exceptions` (bundle + CPU). **Retention**: Workers-specific; upstream Sinatra cannot adopt the stub wholesale. |
| **Sinatra upstream** | `vendor/sinatra_upstream/base.rb` | Phase 15-Pre: `set` / `option?` paths avoid `opal-parser` via `Proc` indirection. **Retention**: upstream behaviour change; belongs as upstream discussion + `lib/opal_patches` coordination. |
| **Rack** | `vendor/rack.rb`, `vendor/rack/{request,utils,show_exceptions,builder.rb}`, `vendor/rack/session/cookie.rb`, `vendor/rack/media_type.rb` | Opal regex / immutability / JSON session coder / Workers eval ban. **Retention**: cross-cutting; many hunks are `(b)` upstream feasibility checks. |
| **OpenSSL stub** | `vendor/openssl.rb` | `nodejs_compat` + Web Crypto bridge for PBKDF/RSA used in demos. **Retention**: Workers environment; not upstream Rack. |
| **Opal gem** | `vendor/opal-gem/opal/opal.rb`, `vendor/opal-gem/opal/corelib/{regexp,error}.rb` | CPU budget (`corelib/irb` drop), regexp `gsub` parity, `UncaughtThrowError` hierarchy. **Retention**: tracked as forked `path:` gem; upstream issues filed per hunk when possible. |
| **Stubs** | `vendor/zlib.rb`, `vendor/tilt.rb`, `vendor/tempfile.rb`, `vendor/rackup.rb`, `vendor/rubygems/version.rb` | Minimal shims for gems Sinatra loads but Workers does not implement. **Retention**: `(a)` candidates to move into `lib/homurabi/stubs/` later. |
| **JWT** | `vendor/jwt/**/*.rb` | Vendored dependency copy; grep hits are mostly version strings — verify diff vs upstream gem when promoting to `(b)`. |

## Classification key

- **(a)** Movable to `lib/` without changing runtime semantics (pure shims /
  require-order glue).
- **(b)** Upstream PR candidate (bugfix / portability).
- **(c)** Must stay vendored for the Workers + Opal combination (document the
  invariant).

## Non-goals (Phase 15-A)

- No vendor file content changes.
- No automatic `git diff` to upstream tarballs — use tagged releases when
  preparing Phase 15-D exports.
