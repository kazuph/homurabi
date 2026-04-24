# Changelog

## 0.2.6 (2026-04-24)

- Initialize SQLite's `integer_booleans` setting for the D1 adapter so Sequel
  boolean writes stay integer-backed (`0` / `1`) instead of drifting to `f` / `t`.
- Keep boolean result coercion resilient when D1 rows surface string-backed
  `t` / `f` values for boolean columns.

## 0.2.5 (2026-04-24)

- Fix Opal/D1 SQL generation for Sequel `insert`, `update`, and `delete` so
  string values are quoted as SQL literals instead of identifiers.
- Coerce simple-table D1 boolean result columns back to Ruby booleans using
  SQLite schema metadata, while leaving ordinary integer columns untouched.

## 0.2.4 (2026-04-23)

- Pin `opal-homura` to `1.8.3.rc1.3` so standalone Opal builds resolve the
  restored `digest` stdlib shim consistently.

## 0.2.3 (2026-04-23)

- Bump the exact `opal-homura` dependency to `1.8.3.rc1.2` for the release retry after the
  previous tag push failed to trigger RubyGems publication.

## 0.2.1 (2026-04-23)

- Correct the published author metadata to "Kazuhiro Homma".

## 0.2.0 (2026-04-23)

- Remove the old `cloudflare-workers-migrate` public executable and expose
  migration compile/apply through `homura db:migrate:*`.

## 0.1.1 (2026-04-23)

- Package the vendored Opal-compatible Sequel subset (`vendor/sequel.rb` and
  `vendor/sequel/**/*`) inside the gem so standalone Workers apps can
  `require 'sequel'` without depending on the monorepo root `vendor/`.

## 0.1.0 (2026-04-20)

- Initial extraction from homura: D1 adapter, Opal Sequel patches, `cloudflare-workers-migrate` CLI.
- `Sequel.connect(adapter: :d1, d1:)` accepts duck-typed D1 bindings (`prepare` / `bind` / `all` / `run`).
- Optional `cloudflare_workers` require for Workers builds.
