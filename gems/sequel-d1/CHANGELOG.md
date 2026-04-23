# Changelog

## 0.1.1 (2026-04-23)

- Package the vendored Opal-compatible Sequel subset (`vendor/sequel.rb` and
  `vendor/sequel/**/*`) inside the gem so standalone Workers apps can
  `require 'sequel'` without depending on the monorepo root `vendor/`.

## 0.1.0 (2026-04-20)

- Initial extraction from homura: D1 adapter, Opal Sequel patches, `cloudflare-workers-migrate` CLI.
- `Sequel.connect(adapter: :d1, d1:)` accepts duck-typed D1 bindings (`prepare` / `bind` / `all` / `run`).
- Optional `cloudflare_workers` require for Workers builds.
