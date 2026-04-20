# Changelog

## 0.1.0 (2026-04-20)

- Initial extraction from homurabi: D1 adapter, Opal Sequel patches, `cloudflare-workers-migrate` CLI.
- `Sequel.connect(adapter: :d1, d1:)` accepts duck-typed D1 bindings (`prepare` / `bind` / `all` / `run`).
- Optional `cloudflare_workers` require for Workers builds.
