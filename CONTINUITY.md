# Continuity Ledger

## Goal（成功基準を含む）
- Finish the queued standalone/build ergonomics fixes and release them as one patch bump for `homura-runtime` and `sinatra-homura`.
- Success means the next session can resume from this file alone and know that implementation is done, validation passed, and only release monitoring / follow-up remains.

## Constraints/Assumptions（制約/前提）
- Priority order is fixed for now: 1 > 3 > 2 > 4.
- Prefer least-surprise behavior for ordinary Ruby/Sinatra developers.
- Build CLI should absorb platform-specific setup when possible instead of forcing app authors into special-case steps.

## Key decisions（重要な決定）
- P1 / auto-await: fix auto-await itself. If a file already contains `.__await__`, generate output and add `# await: true` even when analysis would otherwise produce no inserted await nodes. `--force` may exist for debugging, but should not be required in normal operation. Do not solve this by making `homura build --standalone` bypass auto-await.
- P1 / cf-runtime assets: `homura build --standalone` should ensure/copy `cf-runtime/setup-node-crypto.mjs` and `cf-runtime/worker_module.mjs` from the packaged gem. `homura new` may also scaffold them, but final responsibility belongs to the build CLI.
- P2 / ERB layout yield: port homura-runtime's yield support into `sinatra-homura`'s `homura erb:compile` path so both compilers match. Add diagnostics: support `<%= yield %>` and `<%== yield %>`, but make `<% yield %>` and `yield(arg)` compile errors that point users toward supported layout patterns. Prefer errors over warnings.
- P3 / standalone namespaces: stop hardcoding `AppTemplates` / `AppAssets` in standalone build defaults. Either derive names from the project (for example `HomuraAppTemplates`) or add CLI flags such as `--templates-namespace` / `--assets-namespace`.
- CLI naming: make `homura` the only public CLI surface. Do not keep old `cloudflare-workers-*` names as compatibility aliases before v1.

## State（状態）

### Done（完了）
- Handoff memo received and preserved.
- Parent pane notified via `tmux send-keys -t %170 '[%172] 受領: 4点の優先度と解決方針を保持'`.
- `auto-await` now emits output for files that already contain `.__await__` when the missing piece is only `# await: true`.
- `homura build --standalone` now restores `cf-runtime/` from the packaged runtime gem.
- Both ERB compilers now reject unsupported yield forms (`<% yield %>`, `yield(arg)`) with compile-time guidance.
- Standalone template/asset namespaces now derive from the project name by default, with explicit override flags.
- `homura` is now the only public CLI; build / ERB compile / migrations / scaffolding all dispatch through it.
- Repo build and full test suite passed after the changes and patch-version bumps.

### Now（現在）
- Release metadata is updated locally (`homura-runtime 0.1.5`, `sinatra-homura 0.1.3`).
- Next concrete step is commit / push / tag push, then monitor the release workflow.

### Next（次）
- Commit the completed changes.
- Push `main`.
- Create and push the final patch release tags.
- Monitor the release workflow and RubyGems propagation if requested.

## Open questions（未解決の質問、必要に応じてUNCONFIRMED）
- None for implementation. Release monitoring remains operational work only.

## Working set（作業セット：ファイル/ID/コマンド）
- Likely files:
  - `gems/homura-runtime/exe/auto-await`
  - `gems/homura-runtime/bin/cloudflare-workers-build`
  - `gems/homura-runtime/lib/cloudflare_workers/build_support.rb`
  - `gems/homura-runtime/runtime/setup-node-crypto.mjs`
  - `gems/homura-runtime/runtime/worker_module.mjs`
  - `gems/homura-runtime/lib/cloudflare_workers/version.rb`
  - `gems/sinatra-homura/bin/cloudflare-workers-erb-compile`
  - `gems/sinatra-homura/bin/homura`
  - `gems/sinatra-homura/bin/cloudflare-workers-new`
  - `gems/sinatra-homura/sinatra-homura.gemspec`
  - `README.md`
  - `gems/homura-runtime/README.md`
  - `test/auto_await_cli_test.rb`
  - `test/build_support_test.rb`
  - `test/compile_erb_test.rb`
  - `test/homura_cli_test.rb`
- Reminder command already executed:
  - `tmux send-keys -t %170 '[%172] 受領: 4点の優先度と解決方針を保持' && sleep 0.1 && tmux send-keys -t %170 Enter`
