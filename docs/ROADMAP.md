# homurabi ロードマップ

> 本ドキュメントは Phase 6 以降の中長期計画。
> Phase 1〜5（コア基盤・D1/KV/R2 バインディング・ERB プリコンパイル・回帰テスト 25 件）は完了済み。
>
> 方針メモ:
> - **クライアント側（ブラウザ）で完結できる仕事は Worker でやらない**。
>   PDF 生成・QR コード・Markdown レンダリング等の "見た目を作るだけ" の Gem
>   デモは本ロードマップから除外する（やるならクライアント側 Stimulus/JS で）。
> - Worker でやる価値があるのは **「ネットワーク境界」「シークレット保持」
>   「永続ストレージ」「AI/エッジ計算」** に効く機能のみ。
> - 各 Phase は **1 worktree = 1 Phase**。実装→ドッグフーディング→reviw レビュー
>   →マスター承認、の順を厳守する（CLAUDE.md ルール準拠）。

---

## 全体像

```
Phase 6 ── HTTP クライアント基盤        (Net::HTTP/Faraday → fetch シム)
   │
Phase 7 ── Web Crypto 実体化            (Digest / HMAC / SHA / Random)
   │           ↑ Phase 8 の前提
Phase 8 ── JWT 認証フレームワーク       (jwt gem 動作 + Sinatra ヘルパ)
   │
Phase 9 ── Scheduled Workers (Cron)     (scheduled handler + DSL)
   │
Phase 10 ── Workers AI バインディング   (env.AI ラッパ + Sinatra AI チャットデモ)
```

依存関係:
- Phase 7 は **Phase 8 の前提**（JWT は HMAC が必須）
- Phase 6 は **Phase 10 で OpenAI 互換 API を叩く時に再利用可能**（任意の外部 LLM
  をフォールバックに使うパターン）
- Phase 9 と Phase 10 は独立、並列可

---

## Phase 6 — HTTP クライアント基盤（fetch シム）

### 目的
Ruby Gem 資産の中で **最も波及効果が大きい** のが HTTP クライアント。
Net::HTTP / Faraday / OpenAI クライアント / API ラッパ等、すべてが
この層に依存している。Cloudflare Workers のグローバル `fetch()` を
Ruby 側から自然に呼べるようにする。

### スコープ
- `lib/cloudflare_workers/http.rb`（新規）
  - `Cloudflare::HTTP.fetch(url, method:, headers:, body:)` を実装
  - 戻り値は `Cloudflare::HTTPResponse`（status / headers / body / json メソッド）
  - 内部は JS の `fetch()` に `.__await__` でブリッジ
- **Net::HTTP シム**: `vendor/net/http.rb`（新規スタブ）
  - `Net::HTTP.get(uri)` / `Net::HTTP.get_response(uri)` / `Net::HTTP.post_form(uri, params)`
  - 内部で `Cloudflare::HTTP.fetch` に委譲
  - `Net::HTTPResponse#body` / `#code` / `#[]` 互換
- **URI 周りの補強**（`lib/opal_patches.rb` の URI を URI::HTTP / URI::HTTPS 解析対応に）
- **Faraday は Phase 6 では入れない**（Phase 6.1 として後追い）

### 非スコープ
- 生 TCP / Net::TCP / OpenSSL Socket（Workers が socket API を持たないため不可）
- HTTP/2 push、長時間 keep-alive
- WebSocket クライアント（Phase 10 以降で Durable Objects と一緒に検討）

### 完了条件
1. `Net::HTTP.get(URI('https://example.com'))` が ESM 内で動く
2. `Cloudflare::HTTP.fetch` が POST + JSON ボディ + ヘッダ送信できる
3. 回帰テストに `test/http_smoke.rb` を追加（テスト数 +6）
4. README に "Net::HTTP works" の節を追加

### 想定リスク
- `fetch()` の Response.body は ReadableStream → 一旦 `.text()` / `.arrayBuffer()`
  で全部読む方式にする（Workers の CPU 制限内なら問題なし）
- リダイレクトは `redirect: 'follow'` 既定でユーザに見せず吸収

---

## Phase 7 — Web Crypto 実体化（Digest / HMAC）

### 目的
現状 `vendor/digest.rb` は **NotImplementedError を投げるだけのスタブ**。
JWT 署名検証、CSRF トークン、Cookie 暗号化、すべてここで詰まる。
Web Crypto API (`crypto.subtle`) に委譲して実体化する。

### スコープ
- `vendor/digest.rb` を **本物の実装** に置き換え
  - `Digest::SHA256.hexdigest(str)` → `crypto.subtle.digest('SHA-256', ...)` を await
  - `Digest::SHA1`, `Digest::SHA512`, `Digest::MD5` も同様
  - 同期 API に見せるため、**ビルド時 magic comment `# await: true` を付与**
- `vendor/openssl.rb`（新規・最小）
  - `OpenSSL::HMAC.hexdigest(digest, key, data)` を `crypto.subtle.sign('HMAC', ...)` で実装
  - `OpenSSL::Digest::SHA256` 等のエイリアス
- `SecureRandom` は既に `lib/opal_patches.rb` で実装済み → 流用

### 非スコープ
- RSA / EC 鍵生成（必要になったら Phase 7.1）
- 証明書パース（X.509）

### 完了条件
1. `Digest::SHA256.hexdigest('hello')` が CRuby と同じ結果
2. `OpenSSL::HMAC.hexdigest('SHA256', key, msg)` が CRuby と同じ結果
3. 回帰テスト `test/crypto_smoke.rb` で確定値テスト（テスト数 +5）
4. **Phase 8 (JWT) のブロッカー解消** を README に明記

### 想定リスク
- Web Crypto は基本 async → Opal の `# await: true` で同期化
- `# await: true` を入れた関数のスタックは callstack 1 段増えるが、
  Sinatra ルートの `__await__` と同じパターンなので既知の整合性で OK

---

## Phase 8 — JWT 認証フレームワーク

### 目的
Workers エッジでの API 認証は基本 JWT。`jwt` gem を本物で動かしつつ、
Sinatra に薄い helper を被せて DSL 化する。

### スコープ
- `vendor/jwt/`（新規 vendor）
  - `jwt` gem 本体を vendor、必要なパッチを適用
  - 対応アルゴリズム: HS256 / HS384 / HS512（Phase 7 の HMAC を使用）
  - RS256 / ES256 は Phase 8.1 に分離（鍵生成が必要なため）
- `lib/sinatra/jwt_auth.rb`（新規 Sinatra 拡張）
  - `helpers do; def current_user; end; end` を提供
  - `before { authenticate! }` でルート保護
  - `Authorization: Bearer xxx` ヘッダから抽出
- デモルートを `app/hello.rb` に追加
  - `POST /api/login` → JWT 発行
  - `GET /api/me` → JWT 検証して current_user 返却

### 非スコープ
- OAuth フロー全体（IdP との連携は別 Phase）
- Refresh Token の永続化（KV を使えばすぐできるが、まず JWT 単体）

### 完了条件
1. `JWT.encode(payload, secret, 'HS256')` が CRuby の jwt gem と同じトークンを返す
2. `JWT.decode(token, secret, true, algorithm: 'HS256')` が動く
3. デモルート `/api/login` → `/api/me` が E2E で通る
4. 回帰テスト `test/jwt_smoke.rb`（テスト数 +6）
5. README に「JWT 認証」の節を追加

### 想定リスク
- jwt gem は Base64 / JSON / OpenSSL に依存 → Phase 7 完了が前提
- `jwt` の内部で `String#unpack` を多用 → Opal の挙動を smoke で確認

---

## Phase 9 — Scheduled Workers (Cron Triggers)

### 目的
Cloudflare Workers の `scheduled` ハンドラを Ruby 側から書けるようにする。
バッチ処理・定期同期・データクリーンアップ等のユースケース。

### スコープ
- `src/worker.mjs` に `scheduled(event, env, ctx)` ハンドラを追加
  - `globalThis.__HOMURABI_SCHEDULED_DISPATCH__` に委譲
- `lib/cloudflare_workers.rb` に Scheduled ディスパッチャを追加
  - `event.cron` / `event.scheduledTime` を Ruby に渡す
- **Sinatra に "schedule" DSL を追加**（独自拡張）
  - ```ruby
    class App < Sinatra::Base
      schedule '*/5 * * * *' do
        # 5分ごと実行
      end
    end
    ```
  - 内部的には fetch ハンドラとは別のコールバック登録
- `wrangler.toml` に `[triggers] crons = [...]` の例を追加

### 非スコープ
- 動的な cron 登録（Workers の制約上、wrangler.toml で静的定義のみ）
- 長時間実行（Workers の CPU 制限あり）

### 完了条件
1. `wrangler dev --test-scheduled` で Ruby ハンドラが呼ばれる
2. `schedule '*/1 * * * *'` の DSL が複数登録できる
3. 回帰テスト `test/scheduled_smoke.rb`（テスト数 +3）
4. デモ: 5分ごとに D1 に行を入れる Cron を README に記載

### 想定リスク
- ローカル `wrangler dev` での Cron トリガはマニュアル発火 → CI でどう自動化するか要検討
- Sinatra の DSL を借りるだけで、Sinatra 本体の middleware chain は通さない
  （HTTP リクエストではないため）

---

## Phase 10 — Workers AI バインディング + Sinatra AI チャットデモ

### 目的
**最大の "映え" ポイント**。Sinatra で書いた AI チャット UI が、
裏で Cloudflare Workers AI（**Google Gemma 4** を主役、**OpenAI gpt-oss-120b**
をフォールバックに）を叩く。
"Real Sinatra on the Edge with Real OSS LLM" を README のヒーローに据える。

#### 採用モデル（優先順・2026-04-17 時点の Cloudflare 公式カタログ調査結果）

| 役割 | モデルID | コスト ($/M tok 入/出) | コンテキスト | 日本語 |
|---|---|---|---|---|
| **主役** | `@cf/google/gemma-4-26b-a4b-it` | $0.10 / $0.30 | **256K** | ◯（140+言語） |
| フォールバック | `@cf/openai/gpt-oss-120b` | $0.35 / $0.75 | 128K | ◯ |

#### 不採用（旧メジャー除外ポリシー・マスター方針反映）
- `@cf/qwen/qwen3-30b-a3b-fp8` — **plain Qwen3 は古い**（既に Qwen 3.5 / 3.6
  が出ているため、それらが Workers AI に上がるまで採用見送り）
- `@cf/openai/gpt-oss-20b` — マスター指示により不採用
- `@cf/qwen/qwen2.5-*` 全般 — Qwen 2.5 系で旧メジャー
- `@cf/google/gemma-3-*` / `gemma-7b-it`(Gemma2) — Gemma 4 が現行
- `@cf/mistralai/mistral-7b-instruct-v0.1` / `v0.2` — 旧メジャー
- Llama 系全般 — マスター指示により意図的不採用
- `@cf/deepseek-ai/deepseek-r1-distill-qwen-32b` — distill 元が Qwen2.5
  で世代として中途半端、加えて出力 $4.88/Mtok と高コスト
- `@cf/mistralai/mistral-small-3.1-24b-instruct` — 日本語性能が
  Gemma4 比で弱いため不採用

#### 検証手順（Phase 10 着手時に必須）
1. `wrangler ai models list` で採用 2 モデルの存在を確認
2. 各モデルに「日本語で挨拶して」を投げて出力品質を smoke チェック
3. 公式ドキュメントで料金・コンテキスト窓を再確認（変動するため）
4. Qwen 3.5 / 3.6 系が Workers AI に追加されていたら採用候補に再評価
5. 上記が変わっていたら ROADMAP を即更新してから実装着手

### スコープ

#### 10.1 Workers AI バインディングラッパ
- `lib/cloudflare_workers/ai.rb`（新規）
  - `Cloudflare::AI.run(model, inputs)` → JS の `env.AI.run(...)` を `.__await__`
  - 戻り値は Hash（`response` / `usage` 等）
  - ストリーミングは Phase 10.1 では非対応（次節）
- `wrangler.toml` に `[ai] binding = "AI"` の例
- `env['cloudflare.AI']` で Sinatra ルートから取得可能に

#### 10.2 Sinatra AI チャットデモ
- `app/chat.rb`（新規 Sinatra アプリ、または `app/hello.rb` に追加）
  - `GET /chat` → ERB で会話 UI
  - `POST /chat/messages` → Workers AI を呼んで JSON 返却
  - **会話履歴は KV に保存**（Phase 5 の KV ラッパを再利用）
- `views/chat.erb` / `views/_message.erb`（新規）
- 最小フロントは vanilla JS + fetch、アニメーションはなし
- 既定モデルは `@cf/google/gemma-4-26b-a4b-it`
  （フォールバック: `@cf/openai/gpt-oss-120b`）
- モデル ID は `app/chat.rb` 冒頭で `MODELS = { primary: ..., fallback: [...] }`
  として定数化、差し替え容易に

#### 10.3 ストリーミングレスポンス対応（任意・後追い）
- Workers AI の `stream: true` を Server-Sent Events で返す
- Cloudflare Workers の `Response(ReadableStream)` を Sinatra から返せるよう
  `lib/cloudflare_workers.rb` の build_js_response を拡張
- これは **Phase 10.2 までで動いてから検討**（最初は同期で十分映える）

### 非スコープ
- ベクトル DB (Vectorize) との RAG（Phase 11 候補）
- マルチモーダル（画像入力）（Phase 11 候補）
- ファインチューニング

### 完了条件
1. `Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it', { messages: [...] })`
   が動く（`gpt-oss-120b` フォールバックも smoke テストで検証）
2. `/chat` UI で会話が成立する（ブラウザでドッグフーディング）
3. 会話履歴が KV に永続化されてリロード後も復元される
4. 回帰テスト `test/ai_smoke.rb`（モック Worker AI で）（テスト数 +4）
5. **README のヒーローセクションを書き換え**: "Sinatra + Workers AI チャット"
   のスクリーンショット/GIF を最上部に

### 想定リスク
- Workers AI の課金（Free でも 10,000 neurons/day で十分デモ可能）
- モデル ID は変動するので `app/hello.rb` 内で定数化、移行容易にする
- Gemma 4 / gpt-oss-120b のレスポンス遅延（数秒〜十数秒）は CPU time でなく
  Wall time なので OK、ただし Worker の Wall time 30s 制限は超えないこと
- 主役 Gemma 4 のコストは入力 $0.10/Mtok・出力 $0.30/Mtok と低めだが、
  デモは KV にレスポンスキャッシュを噛ませて更なる課金抑制
- 採用モデルが将来 Workers AI から外れた場合に備え、Phase 10.4 として
  「外部 OpenAI 互換 API（OpenAI / Groq / together.ai 等）に Phase 6 の
  fetch シム経由でフォールバック」を任意で追加できる構造にしておく

---

## Phase 11 候補（参考・未確定）

- Vectorize binding（RAG）
- Durable Objects ラッパ（WebSocket / 永続セッション）
- Queues binding
- Cache API ラッパ
- Email Workers
- Service Bindings
- multipart/form-data の本格対応

---

## 進行ルール

1. **1 Phase = 1 worktree**: `git wt feature/phase6-fetch` のように切って作業
2. **実装後、自分で `npm run dev` 起動 → ブラウザで触る** → ドッグフーディング必須
3. **回帰テスト追加** → `test/smoke.rb` に統合または新規ファイル
4. **`.artifacts/<branch>/REPORT.md` に証跡** → スクショ・テスト出力・ベンチ
5. **`/reviw-plugin:done` でレビュー起動** → マスター承認まで PR 出さない
6. **承認後、PR 作成 → マージ → README 更新 → ロードマップから消す**

---

## 不採用にした選択肢（理由つき）

| 案 | 不採用理由 |
|---|---|
| Markdown レンダラ (kramdown) | クライアント側で marked.js 等で十分 |
| QR コード生成 (rqrcode) | クライアント側 JS ライブラリで完結 |
| PDF 生成 (prawn) | バンドルサイズ肥大・Worker CPU 制限・クライアントで PDF.js |
| Liquid テンプレ | ERB プリコンパイルで足りる、二重持ち不要 |
| シンタックスハイライタ (rouge) | クライアント側で highlight.js / shiki で十分 |
| ActiveRecord | D1 用 adapter を書く工数 vs リターンが見合わない（Sequel の方がまだ筋が良いが Phase 11 以降） |
| Nokogiri | libxml2 ネイティブ依存で物理的に不可 |

→ **判断基準**: 「Worker（=サーバー側）でしかできないか？シークレット・永続化・
AI 等の境界に絡むか？」を Yes と言えるものだけ採用。
