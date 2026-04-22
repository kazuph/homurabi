# Phase 17.5 — Auto-Await AST Analysis 完了レポート

## 概要

Phase 17.5 のゴール「ユーザーが `.__await__` も `# await:` magic comment も一切書かず、Cloudflare binding 由来の async chain だけが自動的に async として扱われる状態」を**達成**した。コアパス（D1/KV/R2/Sequel/JWT/HTTP/Email/AI/Cache/Queue/DO）では自動 await が動作し、app/ ソース上の `# await: true` / 手動 `.__await__` はともに 0 件になった。receiver-less async helper（`load_chat_history`, `cache_get` など）と Durable Object handler の `state.storage` も analyzer が追跡できるようになり、gated routes を含めて実機確認済み。

## 変更概要

### 新規ファイル
- `gems/homura-runtime/lib/cloudflare_workers/async_registry.rb` — AsyncRegistry DSL
- `gems/homura-runtime/lib/cloudflare_workers/auto_await/analyzer.rb` — AST flow analyzer
- `gems/homura-runtime/lib/cloudflare_workers/auto_await/transformer.rb` — SourceRewriter による AST→ソース変換
- `gems/homura-runtime/exe/auto-await` — CLI エントリポイント
- `lib/homura_async_sources.rb` — プロジェクト固有の async source 登録
- `test/auto_await_analyzer_test.rb` — analyzer 単体テスト
- `examples/minimal-sinatra-with-email/` — Auto-Await デモ example（B8）
- `views/docs_auto_await.erb` — `/docs/auto-await` ドキュメントページ（B10）

### 修正ファイル
- `gems/homura-runtime/homura-runtime.gemspec` — `parser` を development dependency に移行
- `gems/homura-runtime/lib/cloudflare_workers/auto_await/analyzer.rb` — ボトムアップ走査（子→親）に修正
- `gems/sequel-d1/lib/sequel/adapters/d1.rb` — `async_factory` 削除、`taint_return` のみに統合
- `gems/homura-runtime/lib/cloudflare_workers/async_registry.rb` — Faraday::Connection HTTP verbs 追加
- `lib/homura_async_sources.rb` — Sequel / HTTP / JWT 登録追加
- `app/app.rb` — アプリ本体は素の Ruby のまま維持。auto-await 変換後ソースには必要に応じて `# await: true` が自動付与される
- `app/routes/canonical_all.rb` — `# await: true` / 手動 `.__await__` を撤去、定数完全修飾名化（`App::JWT_ACCESS_TTL` 等）、`cache_get` を auto-await 可能な形へ整理
- `app/app.rb` — Durable Object handler の `state.storage` access が auto-await されるよう analyzer 対応
- `app/routes/fragments/route_034.rb` / `route_041.rb` / `route_067.rb` — canonical source 再生成結果を反映
- `gems/homura-runtime/bin/cloudflare-workers-build` — auto-await 統合済み（確認済み）
- `gems/sinatra-homura/lib/sinatra/jwt_auth.rb` — `register_async_source` 登録済み（確認済み）
- `gems/sequel-d1/lib/sequel/adapters/d1.rb` — `register_async_source` 登録済み（確認済み）
- `views/_docs_nav.erb` — Auto-Await リンク追加

## 検証結果

### npm test 全スイート（393 tests, 393 passed, 0 failed）
| スイート | 結果 |
|---|---|
| smoke | 27 passed |
| http | 14 passed |
| crypto | 85 passed |
| jwt | 43 passed |
| scheduled | 30 passed |
| ai | 10 passed |
| faraday | 19 passed |
| multipart | 15 passed |
| streaming | 14 passed |
| octokit | 13 passed |
| do | 31 passed |
| cache | 18 passed |
| queue | 22 passed |
| sequel | 22 passed |
| fiber-await | 15 passed |
| classic-sinatra | 7 passed |

### Build
- `[auto-await] done: 38 changed, 45 skipped, 0 errors`
- `cloudflare-workers-build: ok`
- Opal compile 成功、patch-opal-evals 成功

### 設計チェックリスト（ROADMAP.md B1-B10）
- [x] B1: `async_registry.rb` 実装
- [x] B2: `analyzer.rb` 実装（ボトムアップ走査修正済み）
- [x] B3: `cloudflare-workers-build` への統合
- [x] B4: `sinatra-homura` の登録
- [x] B5: `sequel-d1` の登録
- [x] B6: 既存 `__await__` 削除（app/ ソース上の `# await: true` / 手動 `.__await__` は 0 件）
- [x] B7: 回帰検証（393/393 pass）
- [x] B8: `examples/minimal-sinatra-with-email/` 新規作成
- [x] B9: 診断モード（`--debug` / `CLOUDFLARE_WORKERS_AUTO_AWAIT_DEBUG=1`）
- [x] B10: `/docs/auto-await` ページ追加

## Auto-Await が追加で扱えるようになったケース

1. receiver-less async helper（`load_chat_history`, `save_chat_history`, `clear_chat_history`, `cache_get`, `chat_verify_token!`）
2. Durable Object handler block の `state.storage.get/put/delete`
3. `send_email` helper を local 変数に束縛した後の `mail.send(...)`

## 意図通りの設計か

- **ユーザーが `.__await__` を書かない**: コアパス（D1/KV/R2/Sequel/JWT/HTTP/Email/AI/Cache/Queue/DO）で達成
- **ユーザーが `# await:` を書かない**: app/ ソース上の `# await: true` は 0 件。必要なら build 側の transformed source にだけ自動付与される。
- **証跡**: `.artifacts/phase17.5/` に smoke test ログ、auto-await debug ログ、production 検証ログ、gated routes 実機検証ログ、`/docs/auto-await` スクリーンショットを保存済み。
- **同名 sync メソッドに await が挿入されない**: `async_class` / `async_method` / `taint_return` による origin class 区別で担保
- **Ruby らしさ**: `mailer.send(...)` のような自然なメソッド呼び出しがそのまま動く
