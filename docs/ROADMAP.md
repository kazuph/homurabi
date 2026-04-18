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

## 🎯 Gem / ライブラリ採用の優先順位（2026-04-18 確立・マスター指示）

homurabi の価値は「Cloudflare Workers で Ruby を動かす」に加えて
**「既存 Ruby 資産をできる限りそのまま使える状態にする」** こと。自作ミニ実装は
最終手段であり、先に既存 gem を試す。

| 優先度 | 方針 | いつ選ぶ | 前例 |
|---|---|---|---|
| **① 既存 gem をそのまま `require`** | 何も vendor しない、Gemfile に書くだけ | `require 'json'` / `require 'securerandom'` 等、Opal 標準互換で通るもの | Phase 0-5 の大半 |
| **② 既存 gem を vendor（無改変）** | `vendor/foo/` に gem 丸ごと置く、Opal バンドルに含める | pure Ruby・C拡張なし・Opal 非互換 API を踏まない | `mustermann`, 現 `rack/` |
| **③ 既存 gem を vendor + 最小 Opal patch** | vendor した本家の挙動を、`lib/foo_opal_patches.rb` で必要箇所だけ override | Opal / Workers 制約に一部抵触するが中核ロジックは使える | `ruby-jwt` (v2.9.3 + async patch)、**Phase 13 Modern Sinatra** |
| **④ 既存 gem の subset を fork rewrite** | vendor した本家から不要部分を物理削除、コアだけ残す | ②③で解けない eval まみれ・依存爆発を避けたい | （現状なし、避けるべき） |
| **⑤ 自作 mini 実装** | スクラッチで書く | ①〜④で解けない / 本家が巨大すぎて比較の土俵にない | `lib/homurabi_markdown.rb`（kramdown 5k 行の代替）、`lib/cloudflare_workers/*.rb`（Cloudflare binding ラッパ） |

**判断順**: ①から順に試す。`npm run build` で失敗 or smoke test が落ちたら次の優先度へ。
自作 (⑤) は「本家を入れない方が明確に筋が良い」場合のみ選択（小粒な DSL ラッパ、
プロジェクト固有の glue コード、kramdown のような過剰依存の代替）。

関連: `.claude/skills/opal-workers-gem-adoption/SKILL.md` にも同原則を記載
（Phase 11B マージ後にプロジェクトグローバル skill として発動する）。

---

## 全体像

```
✅ Phase 6  ── HTTP クライアント基盤        (Net::HTTP / Cloudflare::HTTP.fetch)
   │            shipped 2026-04-17 (PR #1, commit 48c37a7)
   ↓
✅ Phase 7  ── 暗号プリミティブ完全実装    (Digest / HMAC / Cipher / RSA / EC / Ed25519 /
   │            X25519 / KDF / BN — node:crypto sync + subtle async hybrid)
   │            shipped 2026-04-17 (PR #2, commit 4f53fa1)
   ↓
✅ Phase 8  ── JWT 認証フレームワーク       (ruby-jwt v2.9.3 vendored + Sinatra ヘルパ)
   │            shipped 2026-04-17 (PR #4, commit cd38b52)
   │            HS/RS/PS/ES/EdDSA 全 7 alg 実機 round-trip
   ↓
✅ Phase 9  ── Scheduled Workers (Cron)     (scheduled handler + Sinatra DSL)
   │            shipped 2026-04-17 (PR #6, commit acb8271)
   │            schedule '*/5 * * * *' do |event| ... end
   ↓
✅ Phase 10 ── Workers AI バインディング   (env.AI ラッパ + Sinatra AI チャットデモ
   │            with Gemma 4 + gpt-oss-120b、KV 履歴、JWT 保護)
   │            shipped 2026-04-17 (PR #5, commit 5f71953)
   ↓
✅ Phase 11A ── HTTP foundations              (Faraday shim / multipart / SSE streaming)
   │            shipped 2026-04-18 (PR #8)
   │            34 smoke + /test/foundations 6/6 実機グリーン
   ↓
✅ Phase 11B ── Cloudflare native bindings    (Durable Objects / Cache API / Queues)
   │            shipped 2026-04-18 (PR #9)
   │            71 smoke + DO WebSocket Hibernation + DLQ 実機 round-trip
   ↓
🚧 Phase 12 — Sequel (vendored) + D1 adapter + migration
   │          Sequel 本家 v5.x を `vendor/sequel/` に丸ごと、D1 Database adapter のみ自作
   │          Sinatra × Sequel のゴールデンコンボが homurabi で成立する
   │          Migration は Ruby DSL → SQL 書き出し → `wrangler d1 migrations apply`
   ↓
🚧 Phase 12.5 — Fiber ベース透過 await（「Ruby らしさ」回復パック）
   │          `.__await__` をユーザーコードから消す。Fiber で Promise を sync-shaped
   │          に見せる。`db[:users].all`（`.__await__` なし）が動くことが DoD
   │          Phase 12 マスター指摘「Ruby らしくない点の筆頭」の潰し
   │          ※ Phase 13 前に着手。Sinatra 載せ替えの移動部分を増やす前に
   │             async semantics を先に安定化させる
   ↓
🚧 Phase 13 — Modern Sinatra migration（janbiedermann fork 離脱）
   │          上流 `sinatra/sinatra` 4.x を `vendor/sinatra_upstream/` に固定
   │          `lib/sinatra_opal_patches.rb` で 10-15 箇所だけ override
   │          既存 smoke test 全緑を regression harness として使う
   │          ※ Phase 12.5 完了後。Fiber 透過 await 済みなら上流 Sinatra の
   │             同期想定 code path と衝突しにくい
   ↓
🚧 Phase 11 候補残（未着手）
   └─ Vectorize (RAG、metered コスト有) / Email Workers / Service Bindings /
      ChaCha20-Poly1305 (Phase 7 deferred) / JWE / Phase 10.3 streaming chat
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

## 🚧 Phase 12 — Sequel (vendored) + D1 adapter + Ruby migration DSL

### 目的

Ruby エコシステムの **「AR じゃない方の標準 ORM／クエリビルダ」** である Sequel
（Jeremy Evans 氏メンテ・MIT・pure Ruby・2007〜現在活発）を homurabi に入れて、
Sinatra × Sequel のゴールデンコンボが Cloudflare Workers 上で成立する状態にする。

Phase 3 の生 SQL over `Cloudflare::D1Database#execute` は十分シンプルだが、複雑な
クエリ（JOIN、サブクエリ、WHERE 動的組み立て）を書き始めると生 SQL の文字列結合が
増えてテストしにくくなる。Sequel の DSL で書ければ可読性＋型安全＋ migration まで
一気通貫になる。

### 方針（採用優先順位 ③ = vendor + 最小 Opal patch）

自作 mini 実装（⑤）は **明確に却下**。AR を不採用にしたのと同じ理由で「本家 gem を
使う方が資産価値が高い」。Sequel は pure Ruby・依存ゼロ・eval 依存が AR より
圧倒的に少ないので、vendor + 極小 patch で動く見込み。

### スコープ

1. **Sequel 本家を `vendor/sequel/` に丸ごと固定**（git submodule またはタグ打ちで tarball 展開）
   - 対象: Sequel v5.x の最新安定版
2. **D1 adapter 自作**（`lib/sequel/adapters/d1.rb`）
   - `Sequel::Database` を継承し、10 個ほどのメソッド（`execute` / `execute_insert`
     / `execute_ddl` / `tables` / `schema_parse_table` / etc.）を実装
   - 内部は `Cloudflare::D1Database` を叩く。`__await__` で Promise 解決
   - SQLite dialect 共有（D1 はバックエンドが sqlite3）
3. **Opal patch**（必要箇所のみ `lib/sequel_opal_patches.rb`）
   - `Sequel::Database::ConnectionPool` の Mutex / Thread 前提を no-op 化
   - String mutation (`<<`) を reassignment に書き換え
   - `class_eval(string)` 使用箇所を `define_method` へ（該当あれば）
   - `autoload` の遅延ロード対象で Opal 非互換なものを手動 require に展開
4. **Migration DSL（B 案・build-time only、runtime bundle には入れない）**
   - Sequel の `Sequel.migration do; change do ... end; end` をそのまま使える
   - `bin/homurabi-migrate compile` で Ruby migration を **SQL ファイルに書き出し**
   - 出力を `wrangler d1 migrations apply homurabi-db` が適用
   - migration スクリプト自体は CRuby で走らせる → Opal バンドル増加ゼロ
5. **デモ: `/demo/sequel`**
   - `DB[:users].where(active: true).order(:name).limit(10).all` 相当を返す route
   - 既存 `GET /d1/users` と並置で比較できる
6. **smoke test: `test/sequel_smoke.rb`**
   - `Sequel::Database#execute` が D1 へ届く
   - `dataset#all` / `#where` / `#order` / `#first` / `#insert`
   - migration 生成が期待 SQL を出す（ゴールデンファイル比較）

### 採用優先順位評価

- ①（素 require）: ❌ — Sequel は Gemfile 経由で Bundler が要るが Opal は独自 require 系
- ②（vendor 無改変）: △ — Mutex / `class_eval` で引っかかる箇所が数箇所ある見込み
- **③（vendor + patch）: ✅** ← これを採る
- ④⑤: 不要

### 非スコープ

- **ActiveRecord 互換の magic finder（`User.find_by_name`）は移植しない**
  — Sequel::Model はオプトイン、homurabi はまず Sequel::Dataset DSL だけで十分
- **schema.rb 自動生成は移植しない** — migration が source of truth（Sequel の既定挙動）
- **Connection pool の multi-connection** — Workers は isolate 単一、プールは opt-out
- PostgreSQL / MySQL adapter: D1 専用なので無関係

### 検証手順

1. `npm run build` が Opal エラー出さない
2. `npm test` に `test:sequel` を足して全緑
3. `wrangler dev` で `/demo/sequel` が 200 OK
4. `bin/homurabi-migrate compile` が `.sql` を吐く
5. `wrangler d1 migrations apply homurabi-db --local` で schema 適用
6. 既存 341 テスト全緑維持（regression harness）

### 完了条件

- `vendor/sequel/` に固定バージョン置く
- `lib/sequel/adapters/d1.rb` 実装、`Sequel.connect('d1://')` で接続可能
- `lib/sequel_opal_patches.rb` の override 箇所を全て明示コメント
- `/demo/sequel` 実機グリーン
- `test/sequel_smoke.rb` 最低 10 ケース
- README に Phase 12 節、ROADMAP の「不採用」から AR 項目の但し書きを更新

### 想定リスク

| リスク | 対処 |
|---|---|
| Sequel 内部で `eval(string)` が使われている | grep で発見次第 patch で override、patch 不可なら ④ に格下げ |
| D1 adapter の schema introspection が PRAGMA 系未対応 | D1 が返すエラーを捕捉して fallback クエリへ |
| bundle size 肥大化 | Sequel v5 は ~15k 行。Opal バンドル +500KB 見込み、許容内 |
| migration の可逆性（`change do` の自動反転） | 複雑な ALTER は `up` / `down` を明示させる（Sequel の既定挙動） |

### 想定工数

- vendor 配置 + adapter skeleton: 0.5 日
- D1 adapter 本実装 + Opal patch: 2-3 日
- migration 生成 CLI: 1 日
- smoke + dogfooding + README: 1 日
- 合計目安: **1 週間以内 1 phase = 1 worktree**

---

## 🚧 Phase 13 — Modern Sinatra migration（janbiedermann fork 離脱）

### 目的

現在 homurabi が vendored している `janbiedermann/sinatra` は個人メンテの Opal 特化
fork で、**上流 `sinatra/sinatra` (2024 〜 2026) からの乖離が 10 年近く積み上がって
いる**。マスター指示により「知らない人のフォーク」を採用し続けるリスクを排除し、
**上流 Sinatra 4.x を vendor + 最小 patch** する方式へ移行する。

採用優先順位 ③（vendor + patch）の教科書的ケース。既存 gem の挙動を最大限活かし、
Opal/Workers 制約に触れる箇所だけピンポイントで override。

### 方針

| 選択肢 | 採用？ | 理由 |
|---|---|---|
| A. 上流 vendored + monkey-patch | ✅ | 上流コード無改変、patch ファイル 1 箇所に集約 |
| B. 上流 fork + 最小 diff 運用 | ❌ | fork リポジトリ管理コスト、rebase 負担 |
| C. patch queue（kernel 式） | ❌ | 独自ツール必要 |
| D. subset 自作（homurabi-sinatra） | ❌ | 既存資産活用の原則違反 |

### スコープ

1. **`vendor/sinatra_upstream/`** に上流 sinatra 4.x を固定
   （git submodule with tag pin、初回は tarball 展開でも可）
2. **`lib/sinatra_opal_patches.rb`** を作成、以下の 10-15 箇所を override
3. **janbiedermann fork を `vendor/sinatra/` から削除**
4. **既存 341 テストを regression harness として全緑維持**

### Opal patch リスト（候補）

上流 Sinatra 4.x の Opal/Workers 非互換箇所を棚卸し済み:

| 項目 | 上流挙動 | Opal/Workers 問題 | patch 方針 |
|---|---|---|---|
| `Sinatra::Base.compile!` | route DSL を `class_eval("def #{name}...", __FILE__, __LINE__)` で動的メソッド化 | Workers 禁止: `Code generation disallowed` | `define_method(name, &block)` へ置換 |
| `Sinatra::Base#render` (templates) | `Tilt.new(path).render` — file I/O + Tilt 内部 `eval` | FS なし・eval 禁止 | `HomurabiTemplates` dispatch アダプタに差し替え |
| `Sinatra::Base#process_route` | 同期的に route body 呼ぶ | Opal `# await: true` body は Promise 返す → Sinatra は String 期待で死ぬ | body が Promise なら `__await__` してから戻す patch |
| `throw :halt` / `catch(:halt)` | 同期 control flow | async boundary またぐと `UncaughtThrowError` | halt を `:halt_value` 返り値に変換するシム（Phase 10 `chat_verify_token!` で既知） |
| `String#<<` / `String#replace` | Rack::Utils 等で `path << "/"` | Opal String immutable | 該当箇所のみ reassignment へ |
| `ObjectSpace.each_object` | `Sinatra::Base.subclasses` 探索 | Opal に ObjectSpace なし | `inherited` hook + class 変数で代替 |
| `autoload` の遅延 require 対象 | Tilt / ERB など | 対象 gem が Opal 非互換 | 手動 require を homurabi 版で override |
| `Rack::Protection` の一部 middleware | `/proc/self/status` 読み取り | FS なし | 該当 middleware を `set :protection, ...` で無効化 |
| `Mutex` / `Thread.current` | Rack::Session 周辺 | single isolate | Opal 側 Mutex no-op 既存 patch 流用 |
| `File.read(template)` | static template loader | FS なし | `HomurabiTemplates` dispatch、404 fallback |

**想定 override 箇所: 10-15 箇所、patch ファイル ~300-500 行**

### 段階実装手順

1. **調査フェーズ**（Phase 13.0 — Codex consult + dogfooding）
   - 上流 Sinatra 4.x を `vendor/sinatra_upstream/` に置いて Opal ビルドさせる
   - エラーを実際に列挙（上記「想定」は推測、実機 probe が正義）
   - Phase 12 Sequel と順序前後入れ替えてもよい
2. **patch 実装**（Phase 13.1）
   - `lib/sinatra_opal_patches.rb` を書く
   - override 箇所ごとに「上流該当行 → 置換後の挙動 → 理由」コメント明記
3. **切り替え**（Phase 13.2）
   - `require 'sinatra/base'` の読み込み順を upstream → patches に
   - `vendor/sinatra/` (janbiedermann) を削除
4. **regression 検証**（Phase 13.3）
   - 既存 341 smoke test 全緑
   - `/chat` / `/demo/*` / `/api/*` 全 route を dogfooding
   - `/test/crypto` / `/test/jwt` / `/test/bindings` / `/test/foundations` 全緑
5. **公開**
   - README に Phase 13 節、janbiedermann fork 依存削除の旨記載
   - CLAUDE.md / SKILL.md の「vendored gems」一覧を更新

### 非スコープ

- Sinatra 5.x 先取り（出たらその時）
- Sinatra::Contrib の全拡張移植（必要になったら都度）
- Padrino 互換（homurabi は Sinatra ベース限定）

### 想定リスク

| リスク | 対処 |
|---|---|
| 上流 Sinatra 4.x が想定外の eval / FS 依存を大量に持つ | Phase 13.0 調査フェーズでまず実機確認、想定超なら Phase 再分割 |
| Rack 4 要求（今の homurabi は Rack 3 前提） | 必要なら Rack も同時 upgrade（サブ phase 化） |
| janbiedermann fork 独自機能を既存コードが使っていた | `vendor/sinatra/` 削除前に grep で探索、依存があれば patch 側に移植 |
| 既存 341 テストが上流 Sinatra では通らない箇所がある | regression は patch 側で吸収、無理なら上流へ PR 投げる可能性も（マスター許可必要） |

### 完了条件

- `vendor/sinatra/` (janbiedermann) 物理削除
- `vendor/sinatra_upstream/` に上流タグ固定で配置
- `lib/sinatra_opal_patches.rb` に全 override 集約
- 既存 341 smoke test + `/test/*` self-test 全緑
- README / ROADMAP / SKILL 更新

### 想定工数

- 調査（0.3 日）
- patch 実装（3-5 日・未知数あり）
- regression + dogfooding（1-2 日）
- 合計目安: **1.5-2 週間**（Phase 12 より長い、未知数多いため）

### 進行順

**Phase 12 Sequel → Phase 12.5 Fiber 透過 await → Phase 13 Sinatra 載せ替え** の順。
理由:

- Phase 12 (Sequel) は新規機能追加（規模固定・壊れる範囲狭い）
- Phase 12.5 で `.__await__` を消去して Ruby らしさを回復してから Phase 13 に入ると、
  上流 Sinatra の sync 前提 code path と衝突しにくい
- Phase 13 (Sinatra 載せ替え) は全 route が regression 対象、harness が重要なので
  最後に持ってくる

---

## 🚧 Phase 12.5 — Fiber ベース透過 await（「Ruby らしさ」回復パック）

### 目的

Phase 12 マスター指摘「Ruby らしくない点の筆頭」を潰す。ユーザーコード
（Sinatra ルート内）から `.__await__` を完全に消し去り、**CRuby Sequel / Net::HTTP
/ JWT と同じ見た目**で書けるようにする。

### 現状の問題（2026-04-18 Phase 12 shipped 時点）

```ruby
# 今:
rows = seq_db[:users].where(active: true).order(:name).limit(10).all.__await__
jwt  = JWT.encode(payload, secret, 'RS256').__await__
res  = Net::HTTP.get_response(URI('...')).__await__
```

すべての Promise 返却 API に `.__await__` を付ける必要がある。CRuby との
diff になり、サンプル・ドキュメント・既存 Ruby コードの ported 体験を壊す。

### 目標

```ruby
# こうしたい:
rows = seq_db[:users].where(active: true).order(:name).limit(10).all
jwt  = JWT.encode(payload, secret, 'RS256')
res  = Net::HTTP.get_response(URI('...'))
```

### アプローチ候補（要調査）

#### A. Fiber + Promise.resolve（Opal stdlib 経由）

- Opal 1.8.3.rc1 の Fiber 実装状況を確認する
- Sinatra リクエストハンドラ全体を 1 本の Fiber 内で実行
- `.__await__` を内部 DSL として隠し、`await_all` のような Fiber 自動 yield に包む
- Promise 完了で Fiber resume、caller は sync な値を受け取る

#### B. `# await: true` の伝播を "root async function" で吸収

- Sinatra の root dispatch 関数を async にしておき、ネストした async メソッドの
  Promise 返却を await で解決
- 既に homurabi はこれを部分的にやっている（route body は `# await: true`）
- `.__await__` を「呼ばれたら自動で await される特別マーカー」に昇格できるか？

#### C. Opal 側に `# implicit_await: true` 追加

- 本家 Opal に patch を当てて、一度 await-chain に入ったら以降の async method call を
  自動的に await する機能を追加
- 最も根本的だが Opal 本家 fork が必要、patch maintenance 重い

### DoD（Definition of Done）

1. `app/hello.rb` の既存 route から `.__await__` を可能な限り消す
   - D1 / KV / R2 / Sequel / Net::HTTP / JWT.encode / JWT.decode / Cloudflare::AI.run
   - 消せないものは物理的理由を明記（例: Fiber 内で spawn した background task 等）
2. 既存全 smoke + Workers self-test 全緑（regression）
3. `/demo/sequel` / `/chat` / `/api/login` 等の実機 dogfooding で挙動不変
4. README に Ruby らしさ回復の Before/After 対比を載せる
5. 新パターンに対応した 10 本以上の smoke test
6. **Phase 13 (Sinatra 上流載せ替え) 前提の clean base** を作る —
   上流 Sinatra が想定する sync code path を `.__await__` 消去で邪魔しない状態にする

### 想定リスク

| リスク | 対処 |
|---|---|
| Opal Fiber 実装が不完全 | Phase 12.5.0 調査フェーズで実機 probe、限界が見えたら B 案 / C 案へピボット |
| Workers の event loop と Fiber の相性 | miniflare + production の両方で dogfooding |
| 既存 `.__await__` 呼び出し総数が多すぎる | grep で enumeration、段階移行可能な順序を計画 |
| エラー伝播（Promise reject → Fiber exception） | Fiber#raise ベースで stack trace を温存 |
| 性能劣化 | Fiber 切替コストを bench、許容範囲確認 |
| Phase 13 との順序逆転で Sinatra 上流化後に再調整が発生 | マスター指示で Phase 13 より先に実施、順序固定 |

### 非スコープ

- **Node.js 側の Thread へのマッピング** — Workers isolate 単一スレッド前提維持
- **並列 fiber による真の並行処理** — Promise.all 相当の `parallel` DSL は別 Phase
- **CRuby と完全同一の Fiber 挙動** — Opal の JS ベース Fiber の制約は受け入れる

### 想定工数

- Phase 12.5.0 調査 + Opal Fiber probe: 1-2 日（Opal stdlib 確認、PoC、制約洗い出し）
- 本実装（A or B 案）: 3-5 日
- 既存 `.__await__` call site 移行: 1-2 日
- regression + dogfooding: 1 日
- 合計目安: **1-1.5 週間**（Opal Fiber 次第で上振れ）

### 進行順

**Phase 13（Sinatra 上流載せ替え）より先に実施**（マスター指示 2026-04-19）。
理由:
- Phase 13 で動かす Sinatra 上流コードは CRuby 前提の sync code path を多用する。
  `.__await__` が Sinatra 内部で必要になると patch が余計に膨らむ
- Ruby らしさ（`.__await__` レス）を先に確立すれば、Phase 13 は純粋に
  「Sinatra load-time incompat」の潰しに集中できる
- Phase 12 で Sequel が新たな `.__await__` 発生源を追加したので、Phase 13 に
  進む前に async semantics を一度リファクタする方が diff が小さくなる

---

## 🚧 Phase 11 候補（残り・未着手）

Phase 11A / 11B（shipped）と Phase 12 / 13（計画済）で消化されていないもののみ。

| 候補 | 概要 | 価値 | コスト評価 |
|---|---|---|---|
| Vectorize binding | RAG / セマンティック検索 | Phase 10 の AI チャットを KB 連携へ拡張 | metered 課金あり — deploy 時コスト発生 |
| Email Workers | メール受信→ Ruby ハンドラ | Webhook 的にメール処理 | 本番 Email Routing 必要、miniflare emulator 弱め |
| Service Bindings | Worker→ Worker 間呼び出し | マイクロサービス分割 | miniflare 2 worker でローカル完結、コスト 0 |
| ChaCha20-Poly1305 | pure-JS AEAD 同梱 | Phase 7 で deferred、TLS 1.3 互換性 | pure-JS、コスト 0 |
| JWE（暗号化 JWT） | 機密 payload を含む JWT | Phase 8 の延長 | pure Ruby + Phase 7 crypto、コスト 0 |
| Phase 10.3: Streaming chat | `/chat` 応答を SSE で逐次表示 | UX 改善 | Phase 11A の SSEStream + AI::Stream で部品はあり |
| Phase 10.4: OpenAI 互換 API fallback | Workers AI が落ちた時の外部 API 経由 | 可用性・ vendor lock-in 回避 | Phase 11A Faraday 再利用可 |

### 消化済み（Phase 11A / 11B）

- ✅ Durable Objects ラッパ → Phase 11B
- ✅ Queues binding → Phase 11B
- ✅ Cache API ラッパ → Phase 11B
- ✅ multipart/form-data → Phase 11A
- ✅ Faraday アダプタ → Phase 11A

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
| ActiveRecord | `class_eval(string)` による動的メソッド生成が Workers の `eval` 禁止に抵触、依存 80k 行超、adapter が C 拡張前提。物理的に動かせない。Sequel は Phase 12 で vendor 採用済 |
| Nokogiri | libxml2 ネイティブ依存で物理的に不可 |
| Llama 系モデル全般 | マスター指示により意図的不採用（Phase 10） |
| RSA-PKCS1 v1.5 encrypt | subtle が OAEP のみ提供、OAEP がモダン推奨（Phase 7） |
| ChaCha20-Poly1305 | Web Crypto 標準にも nodejs_compat にもなし、pure-JS 必要（Phase 7 で確認、Phase 11 候補） |

→ **判断基準**: 「Worker（=サーバー側）でしかできないか？シークレット・永続化・
AI 等の境界に絡むか？」を Yes と言えるものだけ採用。
