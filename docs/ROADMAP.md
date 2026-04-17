# homurabi ロードマップ

> Phase 1〜7 完了。Phase 8 以降が中長期計画。
> Phase 1〜5（コア基盤・D1/KV/R2 バインディング・ERB プリコンパイル・回帰 25 件）
> および Phase 6（HTTP fetch シム）、Phase 7（フル暗号スイート）は ship 済み。
>
> 方針メモ:
> - **クライアント側（ブラウザ）で完結できる仕事は Worker でやらない**。
>   PDF 生成・QR コード・Markdown レンダリング等の "見た目を作るだけ" の Gem
>   デモは本ロードマップから除外する（やるならクライアント側 Stimulus/JS で）。
> - Worker でやる価値があるのは **「ネットワーク境界」「シークレット保持」
>   「永続ストレージ」「AI/エッジ計算」** に効く機能のみ。
> - 各 Phase は **1 worktree = 1 Phase**。実装→ドッグフーディング→reviw レビュー
>   →マスター承認、の順を厳守する（CLAUDE.md ルール準拠）。
> - **「妥協選択肢を出すのは禁止」「最大工数で全部実装」**（Phase 7 マスター指示）。
>   不足はNG・追加はOK。プラットフォーム制約で物理不能なものは明記してスキップ。

---

## 全体像

```
✅ Phase 6  ── HTTP クライアント基盤        (Net::HTTP / Cloudflare::HTTP.fetch)
   │            shipped 2026-04-17 (PR #1)
   ↓
✅ Phase 7  ── 暗号プリミティブ完全実装    (Digest / HMAC / Cipher / RSA / EC / Ed25519 /
   │            X25519 / KDF / BN — node:crypto sync + subtle async hybrid)
   │            shipped 2026-04-17 (PR #2)
   ↓
🚧 Phase 8  ── JWT 認証フレームワーク       (jwt gem 動作 + Sinatra ヘルパ)
   │
   ├─ 並列可
   │
🚧 Phase 9  ── Scheduled Workers (Cron)     (scheduled handler + DSL)
   │
🚧 Phase 10 ── Workers AI バインディング   (env.AI ラッパ + Sinatra AI チャットデモ
                                              with Gemma 4 + gpt-oss-120b)
🚧 Phase 11 候補 — Vectorize / Durable Objects / Queues / Cache API / Email
```

依存関係:
- ✅ Phase 7 完了により **Phase 8 の前提（HS/RS/PS/ES/EdDSA 全 algo の sign/verify）が
  すべて揃っている**。jwt gem を vendor して薄いパッチ当てれば即動く見込み
- Phase 6 は **Phase 10 で OpenAI 互換 API を叩く時に再利用可能**
- Phase 9 と Phase 10 は独立、並列可

---

## ✅ Phase 6 — HTTP クライアント基盤（fetch シム） — **shipped (PR #1)**

`Cloudflare::HTTP.fetch` で `globalThis.fetch` を Ruby から呼べるようにし、
`Net::HTTP` シム（`get` / `get_response` / `post_form`）で既存 Ruby HTTP コードを
そのまま動かす。`Kernel#URI` も追加。

### 実装内容（commit `48c37a7`）
- `lib/cloudflare_workers/http.rb` — `Cloudflare::HTTP.fetch` + `HTTPResponse`
- `vendor/net/http.rb` — `Net::HTTP.{get, get_response, post_form}` + `Net::HTTPResponse`
- `lib/opal_patches.rb` — `Kernel#URI(...)` 追加
- 副次成果: Phase 3 期に書かれてた `Kernel.$$raise` typo を発見して fix
  + 回帰テスト 2 本追加（D1Error / KVError 正常 raise）
- `bin/init-local-d1` + `bin/schema.sql`（手動実行・local only・冪等）
- 14 本の HTTP smoke + デモルート 2 本（`/demo/http`, `/demo/http/raw`）

---

## ✅ Phase 7 — 暗号プリミティブ完全実装 — **shipped (PR #2)**

Cloudflare Workers で動く全暗号 algo を実装。**JWT 全 algo (HS/RS/PS/ES/EdDSA) +
RSA-OAEP + AES-GCM/CBC/CTR + ECDH + X25519 + KDF + 完全 BN**。

### 設計
- **node:crypto sync**（Hash / HMAC / KDF / Random / KeyGen / PEM I/O）
- **Web Crypto subtle async**（Cipher / Sign / Verify — Workers の `nodejs_compat`
  が `createCipheriv` / `createSign` / `createVerify` / `publicEncrypt` 未実装
  なため subtle で代替）
- async API は `# await: true` + `.__await__`（D1/KV/R2 と同じパターン）

### 実装内容（commit `4f53fa1`）
| カテゴリ | 実装 |
|---|---|
| Digest | SHA1/256/384/512/MD5（`vendor/digest.rb`） |
| HMAC | 5 algos |
| Cipher | AES-128/192/256-GCM/CBC/CTR — GCM auth_tag/AAD/tampering、CTR 真の streaming、バイト透過 |
| PKey::RSA | gen / PEM / sign / verify (PKCS1) / sign_pss / verify_pss (PSS) / public_encrypt / private_decrypt (OAEP) |
| PKey::EC | P-256/384/521 gen / PEM / sign (DER) / verify (DER) / sign_jwt (raw R\|\|S) / verify_jwt / dh_compute_key |
| PKey::Ed25519 | gen / PEM / sign / verify (EdDSA) |
| PKey::X25519 | gen / PEM / dh_compute_key |
| KDF | PBKDF2-HMAC / HKDF |
| BN | JS BigInt 完全実装（+ - * / % ** mod_exp gcd 比較 num_bits to_s(radix)） |
| SecureRandom | hex / random_bytes / urlsafe_base64 / uuid |
| Workers self-test | `GET /test/crypto`（17 case）+ `bin/test-on-workers`（CI 相当） |

### 検証
- 126/126 テスト緑（既存 27 + http 14 + crypto 85）
- Workers 実機 self-test 17/17 PASS
- Bundle: 5.5MB / gzip 1.15MB（+20KB vs Phase 6）

### プラットフォーム制約で見送り（明記済）
- **ChaCha20-Poly1305**: Web Crypto 標準にも nodejs_compat にもなし。
  pure-JS AEAD 同梱が必要、本 Phase では deferred
- **AES-GCM/CBC mid-block streaming**: subtle が atomic single-shot のため不可。
  CTR は真の streaming 可能（実装済）
- **RSA-PKCS1 v1.5 encrypt**: subtle は OAEP のみ。OAEP（モダン推奨）を使う

---

## 🚧 Phase 8 — JWT 認証フレームワーク

### 目的
Workers エッジの API 認証は基本 JWT。`jwt` gem を vendor し、Sinatra に
薄い helper を被せて DSL 化する。**Phase 7 で全 algo の primitives が
揃ったので、jwt gem は最小限のパッチで動く見込み**。

### スコープ
- `vendor/jwt/`（新規 vendor）
  - `ruby-jwt` gem 本体を vendor、Opal 互換パッチを適用
  - **Phase 7 で揃った primitives を使うため、対応 alg は最初から包括的**:
    - HS256 / HS384 / HS512（OpenSSL::HMAC）
    - RS256 / RS384 / RS512（OpenSSL::PKey::RSA#sign / verify、要 `.__await__`）
    - PS256 / PS384 / PS512（OpenSSL::PKey::RSA#sign_pss / verify_pss）
    - ES256 / ES384 / ES512（OpenSSL::PKey::EC#sign_jwt / verify_jwt — raw R\|\|S）
    - EdDSA（OpenSSL::PKey::Ed25519#sign / verify）
  - JWE（暗号化 JWT）は Phase 8.1 候補
- `lib/sinatra/jwt_auth.rb`（新規 Sinatra 拡張）
  - `helpers do; def current_user; end; end` を提供
  - `before { authenticate! }` でルート保護
  - `Authorization: Bearer xxx` ヘッダから抽出
- デモルートを `app/hello.rb` に追加
  - `POST /api/login` → JWT 発行（HS256 / RS256 / ES256 / EdDSA から選択可能）
  - `GET /api/me` → JWT 検証して current_user 返却
  - `POST /api/login/refresh` → KV 永続 refresh token

### 想定リスク + 対処
- **jwt gem 内部の Sign/Verify が sync 前提** → Phase 7 の sign/verify は
  subtle 経由で async（Promise を返す）。jwt gem 内の RSA/EC sign 呼び出し
  サイトに `.__await__` を仕込む小パッチが必要。HMAC は元々 sync なので無修正で動く。
- **jwt gem の `String#unpack` 多用** → Phase 7 で `unpack1('H*')` パッチ済、
  他の format は smoke で確認しながら追加対応
- **RS/PS/ES の jwt gem 既定エンコード形式**: ES は raw R||S（JWT 標準）→
  Phase 7 の `sign_jwt`/`verify_jwt` をそのまま使える

### 非スコープ
- OAuth フロー全体（IdP との連携は別 Phase）
- JWE（暗号化 JWT）

### 完了条件
1. `JWT.encode(payload, secret, 'HS256')` が CRuby の jwt gem と同じトークンを返す
2. `JWT.decode(token, secret, true, algorithm: 'HS256')` が動く
3. RS256 / PS256 / ES256 / EdDSA 全部 round-trip
4. デモルート `/api/login` → `/api/me` が E2E で通る
5. 回帰テスト `test/jwt_smoke.rb`（最低 12 本: 各 alg の encode/decode）
6. Workers self-test に JWT cases 追加
7. README に「JWT 認証」の節を追加

---

## 🚧 Phase 9 — Scheduled Workers (Cron Triggers)

### 目的
Cloudflare Workers の `scheduled` ハンドラを Ruby 側から書けるようにする。
バッチ処理・定期同期・データクリーンアップ等のユースケース。

### スコープ
- `src/worker.mjs` に `scheduled(event, env, ctx)` ハンドラを追加
  - `globalThis.__HOMURABI_SCHEDULED_DISPATCH__` に委譲
- `lib/cloudflare_workers.rb` に Scheduled ディスパッチャを追加
  - `event.cron` / `event.scheduledTime` を Ruby に渡す
- **Sinatra に "schedule" DSL を追加**（独自拡張）
  ```ruby
  class App < Sinatra::Base
    schedule '*/5 * * * *' do
      # 5分ごと実行
    end
  end
  ```
- `wrangler.toml` に `[triggers] crons = [...]` の例を追加

### 非スコープ
- 動的な cron 登録（Workers の制約上、wrangler.toml で静的定義のみ）
- 長時間実行（Workers の CPU 制限あり）

### 完了条件
1. `wrangler dev --test-scheduled` で Ruby ハンドラが呼ばれる
2. `schedule '*/1 * * * *'` の DSL が複数登録できる
3. 回帰テスト `test/scheduled_smoke.rb`（最低 3 本）
4. デモ: 5分ごとに D1 に行を入れる Cron を README に記載

### 想定リスク
- ローカル `wrangler dev` での Cron トリガはマニュアル発火 → CI でどう自動化するか要検討
- Sinatra の DSL を借りるだけで、Sinatra 本体の middleware chain は通さない
  （HTTP リクエストではないため）

---

## 🚧 Phase 10 — Workers AI バインディング + Sinatra AI チャットデモ

### 目的
**最大の "映え" ポイント**。Sinatra で書いた AI チャット UI が、
裏で Cloudflare Workers AI（**Google Gemma 4** を主役、**OpenAI gpt-oss-120b**
をフォールバックに）を叩く。
"Real Sinatra on the Edge with Real OSS LLM" を README のヒーローに据える。

### 採用モデル（優先順・2026-04-17 時点の Cloudflare 公式カタログ調査結果）

| 役割 | モデルID | コスト ($/M tok 入/出) | コンテキスト | 日本語 |
|---|---|---|---|---|
| **主役** | `@cf/google/gemma-4-26b-a4b-it` | $0.10 / $0.30 | **256K** | ◯（140+言語） |
| フォールバック | `@cf/openai/gpt-oss-120b` | $0.35 / $0.75 | 128K | ◯ |

### 不採用（旧メジャー除外ポリシー・マスター方針反映）
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

### 検証手順（Phase 10 着手時に必須）
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
  - ストリーミングは Phase 10.1 では非対応（10.3 で対応）
- `wrangler.toml` に `[ai] binding = "AI"` の例
- `env['cloudflare.AI']` で Sinatra ルートから取得可能に

#### 10.2 Sinatra AI チャットデモ
- `app/chat.rb`（新規 Sinatra アプリ、または `app/hello.rb` に追加）
  - `GET /chat` → ERB で会話 UI
  - `POST /chat/messages` → Workers AI を呼んで JSON 返却
  - **会話履歴は KV に保存**（Phase 5 の KV ラッパを再利用）
  - **JWT 認証で保護**（Phase 8 の `authenticate!` を使う）← Phase 8 完了が前提
- `views/chat.erb` / `views/_message.erb`（新規）
- 最小フロントは vanilla JS + fetch、アニメーションはなし
- 既定モデルは `@cf/google/gemma-4-26b-a4b-it`
  （フォールバック: `@cf/openai/gpt-oss-120b`）
- モデル ID は `app/chat.rb` 冒頭で `MODELS = { primary: ..., fallback: [...] }`
  として定数化、差し替え容易に

#### 10.3 ストリーミングレスポンス対応
- Workers AI の `stream: true` を Server-Sent Events で返す
- Cloudflare Workers の `Response(ReadableStream)` を Sinatra から返せるよう
  `lib/cloudflare_workers.rb` の build_js_response を拡張
- 10.2 までで動いてから検討

### 非スコープ
- ベクトル DB (Vectorize) との RAG（Phase 11 候補）
- マルチモーダル（画像入力）（Phase 11 候補）
- ファインチューニング

### 完了条件
1. `Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it', { messages: [...] })`
   が動く（`gpt-oss-120b` フォールバックも smoke テストで検証）
2. `/chat` UI で会話が成立する（ブラウザでドッグフーディング）
3. 会話履歴が KV に永続化されてリロード後も復元される
4. JWT 認証で保護されたエンドポイントになる
5. 回帰テスト `test/ai_smoke.rb`（モック Worker AI で）（最低 4 本）
6. **README のヒーローセクションを書き換え**: "Sinatra + Workers AI チャット"
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

## 🚧 Phase 11 候補（参考・未確定）

| 候補 | 概要 | 価値 |
|---|---|---|
| Vectorize binding | RAG / セマンティック検索 | Phase 10 の AI チャットを KB 連携へ拡張 |
| Durable Objects ラッパ | WebSocket / 永続セッション / アクター | リアルタイム機能、AI チャットのストリーム永続化 |
| Queues binding | バックグラウンド job | 非同期処理、retry、Phase 9 と組み合わせ |
| Cache API ラッパ | エッジキャッシュ | 低レイテンシ最適化 |
| Email Workers | メール受信→ Ruby ハンドラ | Webhook 的にメール処理 |
| Service Bindings | Worker→ Worker 間呼び出し | マイクロサービス分割 |
| ChaCha20-Poly1305 | pure-JS AEAD 同梱 | Phase 7 で deferred、TLS 1.3 互換性 |
| multipart/form-data 本格対応 | アップロード | ファイル受信、画像処理連携 |
| Faraday アダプタ | Ruby HTTP gem 互換性 | Phase 6 の Net::HTTP に続く |
| JWE（暗号化 JWT） | 機密 payload を含む JWT | Phase 8 の延長 |

---

## 進行ルール

1. **1 Phase = 1 worktree**: `git wt feature/phase8-jwt` のように切って作業
2. **実装後、自分で `npm run dev` 起動 → ブラウザで触る** → ドッグフーディング必須
3. **回帰テスト追加** → `test/<phase>_smoke.rb` 新規 + `test/smoke.rb` に統合判断
4. **`.artifacts/<branch>/REPORT.md` に証跡** → スクショ・テスト出力・ベンチ・妥協点
5. **`/reviw-plugin:done` でレビュー起動** → マスター承認まで PR 出さない
6. **承認後、PR 作成 → マージ → README 更新 → ロードマップから消す**
7. **「妥協は禁止」** — 不足はNG、追加はOK、最大工数で全部実装。プラットフォーム制約で
   物理的に不可能なものは明記してスキップ（憶測でスキップしない、必ず実機 probe）
8. **Workers self-test 必須** — Node テストだけでなく `bin/test-on-workers`
   相当の in-Worker 検証を必ず追加（Phase 7 で確立した pattern）

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
| Llama 系モデル全般 | マスター指示により意図的不採用（Phase 10） |
| RSA-PKCS1 v1.5 encrypt | subtle が OAEP のみ提供、OAEP がモダン推奨（Phase 7） |
| ChaCha20-Poly1305 | Web Crypto 標準にも nodejs_compat にもなし、pure-JS 必要（Phase 7 で確認、Phase 11 候補） |

→ **判断基準**: 「Worker（=サーバー側）でしかできないか？シークレット・永続化・
AI 等の境界に絡むか？」を Yes と言えるものだけ採用。
