# Changelog

## 0.1.4 — 2026-05-03

- Add the recommended Sinatra-native page API: `render 'Component', props`,
  `share_props`, `set :page_version`, `set :page_layout`, and route helpers
  `defer`, `always`, `optional`, `lazy`, `merge`, `page_errors`,
  `clear_history!`, and `encrypt_history!`.
- Keep existing `inertia_*` helpers/settings and `Inertia.*` prop wrappers
  working for compatibility.

## 0.1.3 — 2026-04-29

- `lib/sinatra/inertia/async_sources.rb` registers under
  `HomuraRuntime::AsyncRegistry` (was `CloudflareWorkers::AsyncRegistry`)
  to follow the homura-runtime 0.3.0 module rename. Pure-Sinatra MRI
  consumers are unaffected (the registration block is gated on
  `defined?(::HomuraRuntime)`). Pin homura-runtime ≥ 0.3.0 if you
  want sinatra-inertia 0.1.3's auto-await registration to fire.

## 0.1.2 — 2026-04-29

- Fix: under Opal/Workers, the Inertia visit JSON body shipped with
  `Content-Type: text/html` and missing `X-Inertia: true` /
  `Vary: X-Inertia` headers. `Response#to_h` is an async function
  (it `await`s any Proc-returned JS Promise), so the rest of the
  `inertia` helper ran after a JS-level suspend; Sinatra finalised
  the response with default headers before the awaited continuation
  set them. We now set the protocol headers *before* touching
  `to_h`, so the response's content type and Inertia headers are in
  place regardless of how the runtime schedules the resumption.
  Pure-MRI behaviour is unchanged.

## 0.1.1 — 2026-04-29

- Add `spec.metadata['homura.auto_await'] = 'true'` so that when this
  gem is consumed via RubyGems alongside `homura-runtime >= 0.2.25`,
  `homura build` automatically adds our `lib/` to the Opal load path
  and runs the auto-await analyzer over our source. 0.1.0 only worked
  when the consumer Gemfile path:-linked us; this is the released
  fix for that.

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
