# Changelog

## 0.3.1 (2026-04-29)

- 0.3.0 was tagged but the release workflow failed before publish
  because `lib/sequel/d1/version.rb` at that tag still showed
  `0.2.10` (the version bump didn't actually land in the 0.3.0
  commit due to a tooling glitch). 0.3.1 ships the actual 0.3.0
  payload — the cloudflare_workers naming-elimination companion
  changes. 0.3.0 was never published to RubyGems.

## 0.3.0 (2026-04-29) — BREAKING: cloudflare_workers naming eliminated

Companion release to homura-runtime 0.3.0. The `homura
db:migrate:compile / db:migrate:apply` user-facing CLIs are
unchanged; only the internal script path they delegate to moved.

| was | now |
|---|---|
| `bin/cloudflare-workers-migrate` (homura db:migrate:* impl) | `exe/homura-db-migrate` |

Internal references that reach into homura-runtime now use
`HomuraRuntime::*` instead of `CloudflareWorkers::*`. Floor on
`homura-runtime ~> 0.3` enforces the rename.

## 0.2.10 (2026-04-27)

- Fix `update(col: Sequel.lit('expr'))` (and `insert(col: Sequel.lit(...))`)
  emitting the literal value as a backtick-quoted identifier on D1, e.g.
  ``UPDATE `todos` SET `done` = `1 - done` `` → SQLite "no such column"
  (homura issue #31). Root cause: in Opal, `Symbol` is the same constant as
  `String`, so `Sequel::LiteralString` and `Sequel::SQL::Blob` (both `String`
  subclasses) match upstream Sequel's `case v when Symbol` branch and get
  routed through `literal_symbol_append`. The homura `literal_append` patch
  now branches on `Sequel::LiteralString` / `Sequel::SQL::Blob` *before* the
  Symbol branch so they take the literal-string / literal-blob paths the way
  CRuby would.

## 0.2.7 (2026-04-24)

- Load auto-await registrations from a lightweight standalone file so consumer
  builds can infer Sequel D1 dataset calls without loading the full adapter at
  analyzer bootstrap time.
- Coerce boolean columns from ordinary D1 dataset reads by querying
  `PRAGMA table_xinfo('table')` with Opal-safe quoting instead of the
  unsupported `db.literal(...)` path.

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
