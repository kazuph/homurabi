# Cloudflare Workers + Opal — entrypoint topology (Phase 15-E)

## 責務分離（確定）

| レイヤ | 役割 |
|--------|------|
| `wrangler.toml` の `main` | **Workers Module のエントリ**（`fetch` / `scheduled` / `queue` / DO クラスを export） |
| `build/worker.entrypoint.mjs`（生成物） | `setup-node-crypto` → **Opal bundle（副作用）** → `worker_module.mjs` の順で import。import path は entrypoint 出力位置からの **相対パス** に自動調整される |
| Opal bundle（例: `build/hello.no-exit.mjs`） | **ビルド成果物**。Rack ディスパッチャ等を `globalThis` に登録 |
| `worker_module.mjs`（gem 同梱） | Rack / Cron / Queue / DO への **純粋な JS アダプタ**（Opal bundle を import しない） |

## 禁止事項

- **ランタイム可変 path import**（例: `import(pathVar)` で Opal bundle を読む）は採用しない。Workers のバンドル解決と並行性の両方で破綻しやすい。

## Before / After（概念）

```mermaid
flowchart LR
  subgraph before["Before (monorepo 固定)"]
    W1[worker.mjs] -->|hard-coded| B1[../../../build/hello.mjs]
  end
  subgraph after["After (Phase 15-E)"]
    E[build/worker.entrypoint.mjs] --> S[setup-node-crypto.mjs]
    E --> O[build/*.mjs Opal bundle]
    E --> M[worker_module.mjs]
  end
```

## homura 本体

- `wrangler.toml` の `main` は `build/worker.entrypoint.mjs`。
- `bundle exec homura build` が ERB / assets / Opal / patch / entrypoint 生成まで一括実行。

## スキャフォールド済みアプリ

- プロジェクト直下に `build/worker.entrypoint.mjs`（`main` と一致）。
- `cf-runtime/` に `setup-node-crypto.mjs` と `worker_module.mjs` をコピー（gem から）。
- `bundle exec homura build --standalone` が consumer 向けパイプラインを実行し、`Gemfile` の `path:` から homura の `vendor/` を追加ロードパスへ取り込み（digest / zlib 等の Workers 向け補助ファイル）。
- low-level `--output` / `--entrypoint-out` を変えても、entrypoint 内 import は出力先からの相対パスに自動調整される。

## Phase 17 — Email Service（`SEND_EMAIL`）

| 項目 | 内容 |
|------|------|
| Wrangler | `[[send_email]]` に `name = "SEND_EMAIL"`（Cloudflare Email Service · Agents Week 2026）。 |
| Rack env | `env['cloudflare.SEND_EMAIL']` は `Cloudflare::Email`（JS `env.SEND_EMAIL.send(...)` を Ruby 側で `await`）。 |
| 備考 | consumer アプリ側で verified sender を wrangler `[vars]` などに載せ、アプリから `from` に渡す。 |

### Phase 17-E — `/cdn-cgi/*`（Rack に渡さない）とバインディング注入

| 項目 | 内容 |
|------|------|
| **`worker_module.mjs` の `fetch` 先頭** | `env.SEND_EMAIL` があれば **`globalThis.__OPAL_WORKERS__.sendEmailBinding`** にコピーしてから Rack を呼ぶ。Miniflare 等で `js_env.SEND_EMAIL` が欠ける場合でも Ruby が同じ JS オブジェクトを拾える。 |
| **`/cdn-cgi/*`** | **Sinatra に渡さない**。Miniflare の entry.worker は `/cdn-cgi/mf/scheduled` だけ先処理する。`/cdn-cgi/handler/email` などはユーザ Worker の `fetch` に届くため、ここで処理しないと Rack が 404 になる。将来 Phase 18（Email 受信）で `export async email(...)` と接続する前提。 |
| **D1 / KV / Queue との違い** | それらは典型的に `env['cloudflare.env']` 経由で JS バインディングを参照する。`SEND_EMAIL` は **Worker の `env` に付く生バインディング**を `worker_module` が先に global に載せ、`Cloudflare::Email` がそれを包む（Rack の `cloudflare.*` はラッパー用の入口）。 |

## wrangler.json について

- **生成・サポート対象は `wrangler.toml` のみ**。`wrangler.json` / `wrangler.jsonc` は手動変換可だが、本ツールチェーンの前提外。
