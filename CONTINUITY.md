# Continuity Ledger

## Goal（成功基準を含む）
- Keep `homura-examples` conventional by fixing least-surprise runtime/gem gaps in this repo instead of pushing workarounds into app code.
- Current success target: verify whether any real framework issues remain after round 7, or whether the remaining friction is now mostly expected Sinatra→Workers adaptation guidance.

## Constraints/Assumptions（制約/前提）
- Prefer least-surprise Ruby/Sinatra behavior even if the implementation underneath diverges from upstream internals.
- Fix the owning gem/runtime layer; do not push special-case code into `homura-examples` unless a finding is clearly example-only.
- `CONTINUITY.md` is the durable source of truth across compression; keep round status and externally verified release state here.
- Round 6 must start only after confirming the child pane chat is cleared and `homura-examples` has no lingering dogfood artifacts or git-history-dependent state.
- For the next round, the only allowed input app is the non-Cloudflare-adapted `sinatra-app`; treat `homura-examples` as a fresh clean-room workspace around that source app only.

## Key decisions（重要な決定）
- Treat explicit `halt` as a dedicated exception carrying a fully materialized Rack tuple so it can cross Opal async boundaries; keep ordinary route returns on Sinatra's existing `throw :halt` path.
- Override `redirect` in the Opal patch layer so awaited routes can end with an ordinary Sinatra-style redirect without degrading into `200 []`.
- Keep standalone consumer apps conventional: ordinary `config.ru` + `require_relative 'app/app'` must pick up the auto-awaited copy under `build/auto_await`.
- Keep precompiled ERB behavior Sinatra-like: `layout.erb` applies by default unless `layout: false` is passed.
- For D1 booleans, coerce only simple-table result columns identified as `BOOLEAN` / `BOOL` via SQLite schema metadata; leave ordinary integer columns untouched.
- Expose Sequel async registrations from a lightweight file (`lib/sequel/d1_async_source.rb`) so consumer standalone builds can load them during analyzer bootstrap.

## State（状態）

### Done（完了）
- Round 5 release set was committed, tagged, pushed, and published:
  - `homura-runtime-v0.2.8`
  - `sequel-d1-v0.2.7`
  - `sinatra-homura-v0.2.12`
- GitHub Actions `Release gems` runs for those three tags completed successfully.
- RubyGems now serves `homura-runtime 0.2.8`, `sequel-d1 0.2.7`, and `sinatra-homura 0.2.12`.
- Child pane `%174` was confirmed idle and then cleared with `/clear` before round 6.
- `homura-examples` was reset to a clean-room starting point:
  - no top-level `.git` repository / git history
  - removed `REPORT_DOGFOOD_174_ROUND3.md`, `REPORT_DOGFOOD_174_ROUND4.md`, `REPORT_DOGFOOD_174_ROUND5.md`
  - removed `homura-app-round3` and `homura-app-round4-backup`
  - removed generated `homura-app/.wrangler`, `homura-app/build`, `homura-app/cf-runtime`, and `homura-app/worker.entrypoint.mjs`
- Round 6 clean-room dogfood completed against published gems (`homura-runtime 0.2.8`, `sequel-d1 0.2.7`, `sinatra-homura 0.2.12`).
- Round 6 verified the released-stack fixes for:
  - standalone auto-await through ordinary `config.ru`
  - D1 boolean reads
  - awaited redirects
  - default ERB layout behavior
- Round 6 repo-side follow-up fixes are implemented locally:
  - `homura-runtime` no longer auto-appends `.__await__` when the source already has it
  - scaffolded apps now include `rake` in `Gemfile`
  - scaffold tests now lock `require_relative 'app/app'` + single `run App` ownership in `config.ru`
  - AI-facing docs now mention scaffolded apps bundle `rake`
- Round 6 follow-up releases were committed, tagged, pushed, and published:
  - `homura-runtime-v0.2.9`
  - `sinatra-homura-v0.2.13`
- GitHub Actions `Release gems` runs for those two tags completed successfully.
- RubyGems now serves `homura-runtime 0.2.9` and `sinatra-homura 0.2.13`.
- User cleaned `homura-examples` further; it now contains only `sinatra-app` plus top-level housekeeping files (`.allow-main`, `.gitignore`).
- Round 7 clean-room dogfood ran from `sinatra-app` only, using published gems (`homura-runtime 0.2.9`, `sequel-d1 0.2.7`, `sinatra-homura 0.2.13`).
- Round 7 reported migration friction around:
  - requiring `sinatra/cloudflare_workers` instead of plain `sinatra/base`
  - switching the DB adapter from SQLite to D1
  - low-level `homura-build` flag usage
- Triage conclusion: no new repo-side blocker is confirmed yet.
  - `require 'sinatra/cloudflare_workers'` is the intended public entrypoint for homura apps, not a bug.
  - `Sequel.connect(adapter: :d1, ...)` with `require 'sequel'` is the intended D1 path; `require 'sequel/d1'` is not the public contract.
  - `bundle exec homura build --standalone --with-db` is the supported workflow; low-level `homura-build` flags and manual `cf-runtime` handling are not the normal user path.
- Round 7 production follow-up confirmed the previously suspicious `asdfasdf` rows were normal user/test data in the D1 database, not a framework/runtime bug.

### Now（現在）
- Round 7 is fully closed, including real deploy / production-path verification.

### Next（次）
- Treat the remaining work as migration guidance / UX polish unless a new deploy-only repro appears.
- If another round is needed, focus on whether any of the remaining adaptations should become more automatic rather than fixing previously resolved runtime blockers.

## Open questions（未解決の質問、必要に応じてUNCONFIRMED）
- Example-only follow-ups remain outside this repo:
  - existing `homura-examples` app docs / local files may still need cleanup
  - existing `homura-app/app/app.rb` still contains a trailing `run App`, even though the scaffold template already avoids that

## Working set（作業セット：ファイル/ID/コマンド）
- Core repo files for the round 6 follow-up release:
  - `gems/homura-runtime/lib/cloudflare_workers/auto_await/transformer.rb`
  - `gems/homura-runtime/lib/cloudflare_workers/version.rb`
  - `gems/homura-runtime/CHANGELOG.md`
  - `gems/sinatra-homura/templates/project/Gemfile.tt`
  - `gems/sinatra-homura/sinatra-homura.gemspec`
  - `gems/sinatra-homura/CHANGELOG.md`
  - `test/auto_await_cli_test.rb`
  - `test/homura_cli_test.rb`
  - `README.md`
  - `public/llms.txt`
  - `skills/homura-workers-gems/quick-start.md`
