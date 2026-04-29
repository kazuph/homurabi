# Changelog

## 0.1.0 — 2026-04-29

* Initial release.
* Full Inertia.js v2 wire protocol: page-object responses, version
  mismatch (409 + X-Inertia-Location), partial reloads
  (X-Inertia-Partial-{Component,Data,Except}), 303 redirect promotion.
* Prop wrappers: `Inertia.always`, `Inertia.defer(group:)`,
  `Inertia.optional` (alias `Inertia.lazy`), `Inertia.merge`,
  `Inertia.once`.
* Class-level DSL: `set :inertia_version`, `set :inertia_layout`,
  `set :inertia_encrypt_history`, `inertia_share do … end`.
* Per-request helpers: `inertia(component, props:)`, `render(inertia:)`
  alias, `inertia_request?`, `inertia_errors`, `inertia_clear_history!`,
  `inertia_encrypt_history!`.
* Auto session sweep of validation errors on render.
* Pure Sinatra dependency (no Rails, no homura coupling).
