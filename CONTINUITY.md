# Continuity Ledger

## Goal（成功基準を含む）
- Keep `homura-examples` conventional by fixing blocker-class runtime/gem gaps in this repo instead of pushing workarounds into app code.
- Current success target: publish the remaining round-3 least-surprise fixes, then dogfood round 4 against the freshly published gems.

## Constraints/Assumptions（制約/前提）
- Prefer least-surprise Ruby/Sinatra behavior even if the implementation underneath must diverge from upstream internals.
- Fix the owning gem/runtime layer; do not push special-case code into `homura-examples`.
- `CONTINUITY.md` is the durable source of truth across compression; keep blocker status here.

## Key decisions（重要な決定）
- Treat explicit `halt` as a dedicated exception carrying a fully materialized Rack tuple so it can cross Opal async boundaries; keep ordinary route returns on Sinatra's existing `throw :halt` path.
- Let `redirect` continue calling `halt`; the new `halt` snapshot logic captures post-mutation status/headers/body so redirect semantics stay conventional in both sync and async routes.
- Strengthen regression coverage in the worker-path smoke instead of trusting direct `app.call` only.
- For `sequel-d1`, keep vendored Sequel packaging and add a subprocess regression that `vendor/` + `lib/` alone can `require 'sequel'` and register the `:d1` adapter.
- For async standalone Sinatra routes, preserve route params by marking Promise-returning `route_eval` paths and skipping `process_route` cleanup for that per-request app instance.
- For D1 booleans, coerce only simple-table result columns identified as `BOOLEAN` / `BOOL` via SQLite schema metadata; leave ordinary integer columns untouched.

## State（状態）

### Done（完了）
- Released and pushed `opal-homura-v1.8.3.rc1.1` from commit `e2fdab6`.
- Released and pushed `homura-runtime-v0.2.2`, `sinatra-homura-v0.2.3`, and `sequel-d1-v0.2.2` from commit `38a1faa`.
- Added worker-path smoke coverage for `params['id']` on both sync and async routes.
- Added worker-path smoke coverage for async `redirect` and async `halt`.
- Patched `sinatra_opal_patches.rb` so explicit `halt` snapshots a full Rack tuple and async Promise rejections resolve back into Sinatra-compatible responses.
- Extended `build_js_response` so resolved async tuples handle `[status, body]` and `[status, headers, body]`.
- Added `sequel_d1_packaging_test.rb` coverage that packaged `vendor/` + `lib/` can `require 'sequel'` and register the `:d1` adapter.
- Implemented the remaining round-3 blocker fixes in the local tree:
  - `homura build --with-db` now implies standalone
  - standalone async Sinatra routes keep `params['id']`
  - simple-table D1 boolean columns coerce to Ruby booleans
  - Sequel DML string quoting regression is covered and fixed
- Current full `npm test` passed on the release-candidate tree.
- Pushed `main` and release tags for `homura-runtime-v0.2.6`, `sequel-d1-v0.2.5`, and `sinatra-homura-v0.2.10`.
- GitHub Actions `release-gems.yml` runs for those three tags completed successfully.
- Cleaned AI-facing docs/skills to the current command surface:
  - removed stale `cloudflare-workers-*` guidance
  - removed the migration playbook from the skill bundle
  - refreshed `README.md`, `public/llms.txt`, and `skills/homura-workers-gems/*` to the modern Rake-first flow
- Implemented round-4 blocker fixes in the local tree:
  - D1 adapter now initializes SQLite integer booleans correctly, so Sequel writes use `0/1`
  - boolean coercion regression coverage now includes string-backed `t/f` rows
  - Rack request authority parsing now preserves non-default ports for redirects in local dev
  - standalone build now auto-detects `config.ru`, `app/hello.rb`, then `app/app.rb`
  - scaffolded apps now use standard `config.ru` + `app/app.rb`, without requiring `app/hello.rb`
- Current full `npm test` passed after the round-4 fixes.

### Now（現在）
- Round-4 blocker fixes are implemented locally; next meaningful step is publishing them.

### Next（次）
- Publish the round-4 blocker fixes in the next gem release set.
- Run the next dogfood pass against those freshly published gems.

## Open questions（未解決の質問、必要に応じてUNCONFIRMED）
- None in local code; release/publish timing is the next external step.

## Working set（作業セット：ファイル/ID/コマンド）
- Files:
  - `gems/homura-runtime/exe/homura-build`
  - `gems/homura-runtime/lib/cloudflare_workers/build_support.rb`
  - `gems/homura-runtime/lib/cloudflare_workers/auto_await/analyzer.rb`
  - `gems/homura-runtime/lib/cloudflare_workers.rb`
  - `gems/sinatra-homura/lib/sinatra_opal_patches.rb`
  - `gems/sequel-d1/lib/sequel/adapters/d1.rb`
  - `gems/sequel-d1/lib/sequel_opal_runtime_patches.rb`
  - `gems/sinatra-homura/templates/project/config.ru.tt`
  - `gems/sinatra-homura/templates/project/app/app.rb.tt`
  - `vendor/rack/request.rb`
  - `test/homura_cli_test.rb`
  - `test/sequel_smoke.rb`
- Validation:
  - `npm test`
