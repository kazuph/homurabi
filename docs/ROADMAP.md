# homura ロードマップ

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

homura の価値は「Cloudflare Workers で Ruby を動かす」に加えて
**「既存 Ruby 資産をできる限りそのまま使える状態にする」** こと。自作ミニ実装は
最終手段であり、先に既存 gem を試す。

| 優先度 | 方針 | いつ選ぶ | 前例 |
|---|---|---|---|
| **① 既存 gem をそのまま `require`** | 何も vendor しない、Gemfile に書くだけ | `require 'json'` / `require 'securerandom'` 等、Opal 標準互換で通るもの | Phase 0-5 の大半 |
| **② 既存 gem を vendor（無改変）** | `vendor/foo/` に gem 丸ごと置く、Opal バンドルに含める | pure Ruby・C拡張なし・Opal 非互換 API を踏まない | `mustermann`, 現 `rack/` |
| **③ 既存 gem を vendor + 最小 Opal patch** | vendor した本家の挙動を、`lib/foo_opal_patches.rb` で必要箇所だけ override | Opal / Workers 制約に一部抵触するが中核ロジックは使える | `ruby-jwt` (v2.9.3 + async patch)、**Phase 13 Modern Sinatra** |
| **④ 既存 gem の subset を fork rewrite** | vendor した本家から不要部分を物理削除、コアだけ残す | ②③で解けない eval まみれ・依存爆発を避けたい | （現状なし、避けるべき） |
| **⑤ 自作 mini 実装** | スクラッチで書く | ①〜④で解けない / 本家が巨大すぎて比較の土俵にない | `lib/homura_markdown.rb`（kramdown 5k 行の代替）、`lib/cloudflare_workers/*.rb`（Cloudflare binding ラッパ） |

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
   │          Sinatra × Sequel のゴールデンコンボが homura で成立する
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
  - `globalThis.__HOMURA_SCHEDULED_DISPATCH__` に委譲
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
（Jeremy Evans 氏メンテ・MIT・pure Ruby・2007〜現在活発）を homura に入れて、
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
   - `bin/homura-migrate compile` で Ruby migration を **SQL ファイルに書き出し**
   - 出力を `wrangler d1 migrations apply homura-db` が適用
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
  — Sequel::Model はオプトイン、homura はまず Sequel::Dataset DSL だけで十分
- **schema.rb 自動生成は移植しない** — migration が source of truth（Sequel の既定挙動）
- **Connection pool の multi-connection** — Workers は isolate 単一、プールは opt-out
- PostgreSQL / MySQL adapter: D1 専用なので無関係

### 検証手順

1. `npm run build` が Opal エラー出さない
2. `npm test` に `test:sequel` を足して全緑
3. `wrangler dev` で `/demo/sequel` が 200 OK
4. `bin/homura-migrate compile` が `.sql` を吐く
5. `wrangler d1 migrations apply homura-db --local` で schema 適用
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

現在 homura が vendored している `janbiedermann/sinatra` は個人メンテの Opal 特化
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
| D. subset 自作（homura-sinatra） | ❌ | 既存資産活用の原則違反 |

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
| `Sinatra::Base#render` (templates) | `Tilt.new(path).render` — file I/O + Tilt 内部 `eval` | FS なし・eval 禁止 | `HomuraTemplates` dispatch アダプタに差し替え |
| `Sinatra::Base#process_route` | 同期的に route body 呼ぶ | Opal `# await: true` body は Promise 返す → Sinatra は String 期待で死ぬ | body が Promise なら `__await__` してから戻す patch |
| `throw :halt` / `catch(:halt)` | 同期 control flow | async boundary またぐと `UncaughtThrowError` | halt を `:halt_value` 返り値に変換するシム（Phase 10 `chat_verify_token!` で既知） |
| `String#<<` / `String#replace` | Rack::Utils 等で `path << "/"` | Opal String immutable | 該当箇所のみ reassignment へ |
| `ObjectSpace.each_object` | `Sinatra::Base.subclasses` 探索 | Opal に ObjectSpace なし | `inherited` hook + class 変数で代替 |
| `autoload` の遅延 require 対象 | Tilt / ERB など | 対象 gem が Opal 非互換 | 手動 require を homura 版で override |
| `Rack::Protection` の一部 middleware | `/proc/self/status` 読み取り | FS なし | 該当 middleware を `set :protection, ...` で無効化 |
| `Mutex` / `Thread.current` | Rack::Session 周辺 | single isolate | Opal 側 Mutex no-op 既存 patch 流用 |
| `File.read(template)` | static template loader | FS なし | `HomuraTemplates` dispatch、404 fallback |

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
- Padrino 互換（homura は Sinatra ベース限定）

### 想定リスク

| リスク | 対処 |
|---|---|
| 上流 Sinatra 4.x が想定外の eval / FS 依存を大量に持つ | Phase 13.0 調査フェーズでまず実機確認、想定超なら Phase 再分割 |
| Rack 4 要求（今の homura は Rack 3 前提） | 必要なら Rack も同時 upgrade（サブ phase 化） |
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
- 既に homura はこれを部分的にやっている（route body は `# await: true`）
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

---

## 🚧 Phase 15 — Gemification（「フォークして使う」から「gem install するだけ」へ）

### 背景・動機（マスター指示 2026-04-20）

Phase 13 で janbiedermann fork を離脱し、上流 Sinatra 4.x に揃ったことで、homura が
「**Cloudflare Workers で動く実用 Sinatra スタック**」として完成した。次の段階は
**「他の Ruby 開発者が、自分の既存 Sinatra アプリにこれを取り込めるようにする」** こと。

「VPS / EC2 を契約しない限り Ruby が動かせない」状態から「**gem install で Cloudflare のエッジに乗る**」
へのパラダイム転換を狙う。

#### 計画策定の経緯（v1 → v2）

- **v1 (2026-04-20 朝)**: 5 gem 構成 / Phase 15-A で hello.rb 分割 + build 汎用化 + CPU budget
  を一括処理 / サンプルアプリは別リポジトリ
- **Codex divergent review (2026-04-20 昼)**: 以下を強く指摘
  1. **5 gem は多すぎ** — まず 3 gem (`runtime` / `sinatra-cfw` / `sequel-d1`) で止めろ。
     `cloudflare-workers-jwt` と `cloudflare-workers-http` は「境界」ではなく「patch 束」で、
     gem 化する境界が立っていない
  2. **Phase 15-A で CPU budget を並行処理するな** — クリティカルパスを伸ばす。別 phase に独立せよ
  3. **toolchain 契約 (`worker.mjs` ↔ Opal compile flags ↔ globalThis 名前) の抽出** が
     hello.rb 分割より先。Phase 15-A はこれだけで切れ
  4. **サンプルは monorepo `examples/` で同居** させよ。別リポは release cadence が
     分かれてから
  5. **外部 dogfooder を探す前に、既存 Sinatra 小アプリを自分で 1 本移植** して beta 候補にせよ
- **v2 (このドキュメント)**: 上記指摘を全面採用し、最終 3 gem / Pre 独立 / 5 段プランに再構成

#### 現状（2026-04-20 アーキテクチャ歪み診断）

- gem 化容易性スコア **25-30/100** — 内核は意外と clean、外殻が homura 専用に焼かれてる
- `app/hello.rb` 2,814 行に library 的ヘルパと demo route が混在（境界が見えてない）
- `package.json` / `bin/*` が `app/hello.rb`・`views/`・`homura_templates` を hardcode
- `src/worker.mjs` が `__HOMURA_*` グローバル名で固有化（14 箇所）
- `lib/sequel/adapters/d1.rb:35` が `require 'cloudflare_workers'` 直結（要 hook 化）
- `vendor/sequel/*` に inline `# homura patch:` コメント付きの class_eval→define_method
  改変が散在（vendor 改変 + lib 側 monkey patch の二重戦略）
- `lib/sinatra_opal_patches.rb:53` の `defined?(::Cloudflare::BinaryBody)` gate
  1 箇所だけが Cloudflare 結合（容易に外せる）

#### 理想形（Phase 15 完了後）

```ruby
# 既存 Sinatra ユーザーの Gemfile に 1-2 行足すだけ
gem 'sinatra'
gem 'sinatra-homura'  # ← これが核
gem 'sequel-d1'                   # ← optional (DB 使うなら)

# config.ru もしくは app.rb（既存 Sinatra コードはそのまま）
require 'sinatra/base'
require 'sinatra/cloudflare_workers'   # patches 自動 install + Rack adapter 起動

class MyApp < Sinatra::Base
  get '/' do; 'hello from edge'; end
end

run MyApp
```

```bash
bundle exec rake cloudflare_workers:build
npx wrangler deploy
```

### 進行原則

- **3 gem に絞る**（v1 の 5 gem 案から降格）。`jwt` / `http` shim は homura 内に温存し、
  境界が立ってから将来 gem 化（Phase 15-Future として記録）
- **Sinatra/Sequel は完全 opt-in**。`homura-runtime` (core) は Sinatra も
  Sequel も知らない
- **vendor 改変は禁止方向**。すべて外部 monkey patch (`require` 後に `prepend` /
  `class_reopen`) に統一。vendor 改変が残るのは「上流 PR で吸収するまでの暫定」のみで、
  必ず TODO 化
- **homura リポジトリは「showcase アプリ」として残す** — gem を `path:` 指定で依存し、
  常に dogfooding 環境として機能する
- **gem は monorepo 起点**（`gems/<name>/` サブディレクトリ）→ 安定したら別リポへ promote
- **サンプルアプリは monorepo `examples/` で同居**（v1 案の別リポは却下）。CI 漂流防止
- **外部 dogfooder を待たず、自分で既存 Sinatra 小アプリを 1 本移植** して beta 候補にする
- **CPU budget 問題は Phase 15-Pre で独立解決**（v1 案の Phase 15-A 並行は却下）。
  クリティカルパスを切らないため

### スコア達成目標と段階

| Phase | 目標スコア | 内容 |
|---|---:|---|
| 開始時点 | 25 | 現状（hello.rb 2,814 行、build script project-specific） |
| Phase 15-Pre 完了 | 25 (gemスコア変化なし、deploy 安定化) | CPU budget 削減：起動 < 300ms / バンドル < 5MB / 連続 deploy 成功 |
| Phase 15-A 完了 | 35 | toolchain 契約抽出（worker.mjs 汎用化 + build CLI 引数化 + vendor 棚卸し） |
| Phase 15-B 完了 | 55 | `homura-runtime` gem 切り出し（コア層） |
| Phase 15-C 完了 | 80 | `sinatra-homura` gem 切り出し（本命・ユーザー接点）+ examples/ + 移植 dogfood |
| Phase 15-D 完了 | 90 | `sequel-d1` gem 切り出し |
| Phase 15-Future | 95+ | jwt/http の gem 化（境界が立ってから） |

---

### Phase 15-Pre — Cloudflare Workers 起動 CPU budget 削減（独立先行）

**目的**: gem 化のクリティカルパスに絡まないところで先に解決する。Phase 14 で発生した
deploy 不安定（連続 deploy で startup CPU 制限超過）を潰し、以降の Phase で安心して
deploy できるようにする。

#### 背景

`.artifacts/phase14-posts-login-navi/REPORT.md` 記載のとおり、

- バンドルサイズ 6.7MB / Gzip 1.3MB / 119,629 行
- 起動 350-380ms（Workers Paid Standard 上限 ~400ms 張り付き）
- `npx wrangler deploy` が「1 回目通って 2 回目落ちる」現象

#### スコープ

1. **Opal stdlib 削減**
   - `vendor/opal-gem/stdlib/` から homura 未使用のものを排除
   - 候補: `minitest*` / `benchmark*` / `iso-8859-*` / `windows-*` 等のエンコーディングテーブル /
     stringio の一部
   - 想定効果: 起動 -30〜40% / バンドル -2〜3MB
2. **Mustermann dialect 絞り込み**
   - `vendor/mustermann/` を Sinatra / Regular dialect だけに絞る
   - Template / Rails / Shell dialect 除去
   - 想定効果: -100KB / 数万行
3. **Sinatra extension の絞り込み**
   - `Sinatra::ShowExceptions` — production 不要
   - `Sinatra::CommonLogger` — Cloudflare 側 logging で代替
4. **計測の自動化**
   - `npx wrangler deploy --dry-run` で startup CPU profile を取る CI step
   - バンドルサイズの per-Phase 増分を REPORT に記録

#### DoD

- 起動 < 300ms / バンドル < 5MB
- `wrangler deploy` を **連続 3 回成功**（deploy 安定）
- 既存全 smoke + 全 dogfood ルート緑

#### 想定リスク

| リスク | 対処 |
|---|---|
| stdlib 削減で意外な箇所が壊れる | smoke 全緑を回帰条件に。1 つずつ削って bisect |
| Mustermann dialect 削減で route 解析エラー | Sinatra 4.x が依存する dialect だけ残す |
| 削減後も依然 CPU 超過 | Cloudflare Paid Standard 引き上げ依頼（最終手段） |

#### 想定工数: **3-5 日**

---

### Phase 15-A — toolchain 契約抽出（gem 化前提工事・最小粒度）

**目的**: gem 化に最も効く「ビルドパイプライン契約 ↔ JS bridge ↔ Opal compile flags」
の三点を汎用化する。**hello.rb 分割は意図的に Phase 15-C へ移送**（gem 切り出しと
セットでやる方が手戻り少ない、という Codex 指摘を受け入れ）。

#### スコープ

1. **`src/worker.mjs` の `__HOMURA_*` 名前空間化**
   - `__HOMURA_RACK_DISPATCH__` → `globalThis.__OPAL_WORKERS__.rack` のような namespace 化
   - DO / Queue / Scheduled / WS handler 全部同様に
   - homura 側からは `register_dispatcher(:rack, fn)` のような hook で登録
   - **DoD**: `src/worker.mjs` 内に `HOMURA` 文字列ゼロ
2. **build script の引数化**
   - `bin/compile-erb` に `--input` `--output` `--namespace` argv 追加
   - `bin/compile-assets` に同様
   - `bin/patch-opal-evals.mjs` を generic CLI 化
   - homura 側は `Rakefile` 経由で呼ぶ:
     ```ruby
     namespace :build do
       task :erb do
         sh 'bin/compile-erb --input views --output build/homura_templates.rb ' \
            '--namespace HomuraTemplates'
       end
     end
     ```
   - `package.json` の `build:opal` も `--input app/hello.rb --output build/hello.no-exit.mjs` の
     ENV/argv 化、ハードコード除去
   - **DoD**: `npm run build` の入出力が固有名を含まない、ENV/argv で全部上書き可能
3. **vendor 改変の棚卸し**（Phase 15-D 移植準備）
   - `vendor/sequel/`, `vendor/sinatra_upstream/`, `vendor/jwt/` 等を grep で改変箇所列挙
   - `docs/VENDOR_PATCHES.md` を新設してエントリ全部書き出す
   - 各箇所について: (a) lib 側 monkey patch に移せるか / (b) 上流 PR 候補か / (c) 留保理由
   - **DoD**: 「移せない理由つき」のものだけが vendor 改変として残る
4. **「toolchain 契約書」を文書化**
   - `docs/TOOLCHAIN_CONTRACT.md` を新設
   - JS↔Ruby の dispatch 名前空間 / Opal compile flags / build artifact 命名規則 /
     wrangler.toml の必須 binding を明記
   - これが gem 切り出し時の interface 仕様書になる

#### 非スコープ（v1 から降格）

- `app/hello.rb` の分割 → **Phase 15-C へ**（sinatra-cfw gem 切り出しとセット）
- CPU budget 削減 → **Phase 15-Pre で独立済**

#### 想定リスク

| リスク | 対処 |
|---|---|
| worker.mjs 名前空間化で wrangler dev のホットリロード壊れる | 段階移行、各 dispatcher を 1 つずつ移行 |
| build CLI 引数化で `npm run dev` が壊れる | npm scripts は薄い wrapper として残し、内部だけ汎用化 |

#### 想定工数: **1 週間**

---

### Phase 15-B — `homura-runtime` gem 切り出し（コア層）

**目的**: Sinatra も Sequel も知らない、**最小コア** を gem 化。他 gem (15-C, 15-D) は
これに依存する。

#### スコープ

1. **monorepo 内に `gems/homura-runtime/` 作成**
   ```
   gems/homura-runtime/
     homura-runtime.gemspec
     lib/cloudflare_workers.rb            # 783 行 → そのまま
     lib/cloudflare_workers/
       d1.rb / kv.rb / r2.rb / ai.rb / queue.rb /
       durable_object.rb / cache.rb / http.rb /
       scheduled.rb / multipart.rb / stream.rb
     lib/opal_patches.rb                  # 649 行 → そのまま
     runtime/worker.mjs                   # Phase 15-A で汎用化済み
     runtime/setup-node-crypto.mjs
     runtime/wrangler.toml.example
     README.md / CHANGELOG.md
   ```
   - homura の `Gemfile`: `gem 'homura-runtime', path: 'gems/homura-runtime'`
   - 既存の `lib/cloudflare_workers*` `lib/opal_patches.rb` `src/worker.mjs` は削除
2. **gem の対外 API を確定**
   - Ruby 側: `Cloudflare::{D1Database,KV,R2,AI,Queue,HTTP,DurableObject}` ＋
     `CloudflareWorkers.register_rack(app)` `register_scheduled` `register_queue`
   - JS 側: `globalThis.__OPAL_WORKERS__.{rack,scheduled,queue,do}.{...}`
3. **gem ユーザー向け wrangler.toml テンプレート提供**
   - D1 / KV / R2 / AI / DO / Queue それぞれの opt-in 例
4. **homura 自身が新 gem を path 依存で動く**
   - 既存の全 smoke + 全 dogfood が緑のまま gem 化を達成
5. **README に「他の Ruby アプリで使う方法」**
   - 最小サンプル（Sinatra なし、Rack だけ）
   - 「Sinatra 使うなら Phase 15-C も入れて」と誘導

#### 非スコープ

- rubygems.org への push（**Phase 15-D 後にまとめて**）
- semver 安定化（v0.x で動く版を出すことが優先）

#### 想定リスク

| リスク | 対処 |
|---|---|
| gem 化で require path 壊れる | smoke 全緑を回帰条件 |
| `runtime/worker.mjs` が wrangler の build 解決でハマる | gem 内 path を解決できるか実機確認 |
| Opal の require 解決と Bundler の require 解決の二重戦略 | Opal の `-I` flag で gem の lib path を明示 |

#### 想定工数: **1 週間**

---

### Phase 15-C — `sinatra-homura` gem 切り出し（本命・ユーザー接点）

**目的**: マスター本来の目的「**既存 Sinatra ユーザーが gem install するだけで Workers
にデプロイできる**」を達成する核心 gem。**Phase 15-A で降格された hello.rb 分割もここで実施**
（gem 切り出しとセットにする方が境界が見えやすい）。

#### スコープ

1. **`app/hello.rb` 分割**（v1 案の Phase 15-A から移送）
   - 2,814 行 → 200 行 + 複数の小ファイル
   - `app/app.rb` — Sinatra::Base サブクラス本体
   - `app/routes/{demo,test,api,posts,login}.rb`
   - `app/helpers/{session_cookie,chat_history,markdown_render}.rb`
   - **DoD**: hello.rb 削除 (or 200 行以下)、全 smoke + 全 dogfood ルート挙動不変
2. **monorepo 内に `gems/sinatra-homura/` 作成**
   ```
   gems/sinatra-homura/
     sinatra-homura.gemspec
     lib/sinatra/cloudflare_workers.rb     # extension 入口
     lib/sinatra_opal_patches.rb           # 352 行 → defined? gate 1 箇所外して clean に
     lib/sinatra/jwt_auth.rb               # 142 行（JWT 拡張は当面ここに同梱）
     lib/sinatra/scheduled.rb              # Sinatra DSL 拡張
     lib/sinatra/queue.rb                  # 同上
     templates/wrangler.toml.example
     templates/Rakefile.example
     bin/cloudflare-workers-erb-compile    # ERB precompile CLI
     bin/cloudflare-workers-build          # 全 build orchestrator
     README.md
   ```
   - 依存: `homura-runtime` (15-B)、`sinatra` ~> 4.2、`mustermann`、`rack` ~> 3
   - **vendor/sinatra_upstream/ は gem には含めない**（gem ユーザーが `gem 'sinatra'` する）
3. **`require 'sinatra/cloudflare_workers'` 一発で patches 自動適用**
   - Sinatra::Base に prepend して route compile / dispatch を Promise 透過にする
   - `CloudflareWorkers.register_rack(MyApp)` を裏で自動呼び出し
4. **ERB precompile CLI を gem 提供**
5. **Rake task テンプレート**: `cp templates/Rakefile.example` で `rake cloudflare_workers:{build,dev,deploy}` が動く
6. **「3 ファイルで動く」最小サンプルを `examples/minimal-sinatra/` に同居**（v1 の別リポ案を撤回）
   - 中身: `Gemfile` + `app.rb` + `wrangler.toml` の 3 つだけ
   - CI で常時ビルド検証
7. **既存の自分の Sinatra 小アプリを 1 本移植** して `examples/` に置く（自己 dogfood）
   - 候補: 過去に書いた個人ブログ / 簡易 API のうち、規模感が手頃なもの
   - 既存 Sinatra アプリが「Gemfile に 2 行足すだけ」で edge に乗ることを実証
8. **既存 homura が新 gem を path 依存で動く**
   - 全 smoke 緑

#### 非スコープ

- Sinatra::Contrib 全拡張対応（必要になったら都度）
- Hanami / Roda 対応（Phase 16+ 候補）
- jwt_auth.rb の独立 gem 化（Phase 15-Future）

#### 想定リスク

| リスク | 対処 |
|---|---|
| `defined?(::Cloudflare::BinaryBody)` gate を完全に外したい | Cloudflare::BinaryBody は CFW gem から expose して直接 require |
| Sinatra 4.x のマイナーバージョン互換 | `add_dependency 'sinatra', '~> 4.2'` で固定 |
| 自己 dogfood の小アプリ移植で想定外バグ | 移植時 issue は homura で fix → gem に反映 |

#### 想定工数: **2 週間**（hello.rb 分割 + gem 切り出し + dogfood で長め）

---

### Phase 15-D — `sequel-d1` gem 切り出し（DB 派・opt-in）

**目的**: ORM が必要なユーザー向けの opt-in gem。これで「3 gem」が完成する。

#### スコープ

1. **monorepo 内に `gems/sequel-d1/` 作成**
   ```
   gems/sequel-d1/
     sequel-d1.gemspec
     lib/sequel/adapters/d1.rb              # 276 行
     lib/sequel_opal_patches.rb
     lib/sequel_opal_async_dataset_patches.rb
     lib/sequel_opal_runtime_patches.rb
     bin/cloudflare-workers-migrate         # bin/homura-migrate を generic 化
     README.md
   ```
   - **vendor/sequel/ の inline 改変は事前に上流 PR or lib 側 monkey patch に移行済前提**
     （Phase 15-A の vendor 棚卸しと連動）
   - 依存: `sequel` ~> 5.x、`homura-runtime`
2. **`lib/sequel/adapters/d1.rb:35` の `require 'cloudflare_workers'` 直結を解消**
   - `Cloudflare::D1Database` を duck-typed interface として受け取る pattern に
3. **対外 API**
   - `Sequel.connect(adapter: :d1, d1: env['cloudflare.env'].DB)`
   - migration: `bin/cloudflare-workers-migrate compile db/migrations`
4. **examples/minimal-sinatra-with-db/** を `examples/` に追加（Sinatra + sequel-d1 の最小例）
5. **rubygems.org への push 検討**
   - 全 3 gem の README / CHANGELOG / version.rb 整備
   - semver 1.0 を出す前に Phase 15-C で移植した dogfood アプリの稼働実績で正当化
   - マスター承認後に `gem push` (3 gem まとめて)

#### 非スコープ

- ChaCha20-Poly1305 / JWE 等の暗号拡張（Phase 11 候補から継続）
- Vectorize / Email Workers / Service Bindings（Phase 11 候補から継続）

#### 想定工数: **1.5 週間**

---

### Phase 15-Future — jwt / http の gem 化（境界が立ってから）

**現時点では gem 化しない**理由（Codex 指摘・採用）:

- `cloudflare-workers-jwt` 候補
  - 含む予定だった: `vendor/jwt/` 改変分 + `lib/sinatra/jwt_auth.rb`
  - **問題**: Sinatra extension が混ざっていて「JWT というドメイン」と「Sinatra 拡張」の
    境界が立っていない。gem 名と中身がズレる
  - 当面: `vendor/jwt/` は homura に残し、`lib/sinatra/jwt_auth.rb` は
    `sinatra-homura` gem (15-C) に同梱
  - **gem 化条件**: JWT を Sinatra 以外（Rack / Hanami / Roda）から呼ぶユースケースが
    具体化したら独立 gem に切り出す
- `cloudflare-workers-http` 候補
  - 含む予定だった: `vendor/faraday.rb` + `vendor/net/http.rb` shim
  - **問題**: shim は homura-runtime の `Cloudflare::HTTP` に強く依存し、
    実質「core gem の拡張」。独立 gem の意義が薄い
  - 当面: `vendor/faraday.rb` `vendor/net/` は `homura-runtime` (15-B) に
    同梱（または `homura-runtime-net-http` 互換 shim として core 内に置く）
  - **gem 化条件**: Faraday adapter として独立して使いたいユーザーが現れたら切り出す

これらは **「成功のシグナルが見えてから動く」** 方針。境界が立たないうちに gem を増やすと
namespace 衝突 / version matrix / メンテ負荷が逆に上がる、という Codex 指摘を踏襲。

---

### Phase 15 全体の完了条件（v2）

1. **Gem 構成（最終形）**: **3 gem**（v1 の 5 gem から降格）
   - `homura-runtime` — コア（必須・Sinatra も Sequel も知らない）
   - `sinatra-homura` — Sinatra ユーザー向け（最も入口になる gem、JWT 拡張も同梱）
   - `sequel-d1` — DB 使う人向け（opt-in）

2. **homura リポジトリ自身が「showcase アプリ」として動く**
   - 3 つの gem を `path:` 依存で参照
   - 既存 全 smoke + 全 dogfood ルートが緑
   - README が「homura を使う」ではなく「**この技術スタックを自分のアプリに導入する**」誘導に書き換わる

3. **`examples/` に 2 つの最小サンプル + 1 つの自己移植アプリが同居**（v1 の別リポ案撤回）
   - `examples/minimal-sinatra/` — 3 ファイル（Gemfile + app.rb + wrangler.toml）
   - `examples/minimal-sinatra-with-db/` — 上記 + sequel-d1 例
   - `examples/<自己移植アプリ>/` — 既存 Sinatra アプリを `Gemfile` に 2 行足して edge 化した実例
   - CI で全 examples を常時ビルド検証

4. **gem 化容易性スコア 90+/100**

5. **CPU budget 問題が Phase 15-Pre で解決済**
   - 連続 deploy が落ちない / 起動 < 300ms / バンドル < 5MB

6. **`docs/TOOLCHAIN_CONTRACT.md` と `docs/VENDOR_PATCHES.md` が最新**

### 進行順序の確定（v2）

```
Phase 15-Pre (CPU budget 削減・独立)        ← 3-5 日
  └─ DoD: 連続 deploy 成功、起動 < 300ms、バンドル < 5MB
       ↓
Phase 15-A (toolchain 契約抽出・最小粒度)   ← 1 週間
  └─ DoD: worker.mjs から HOMURA 文字列ゼロ、build CLI 引数化、
        VENDOR_PATCHES.md 完成、TOOLCHAIN_CONTRACT.md 完成
       ↓
Phase 15-B (homura-runtime gem) ← 1 週間
  └─ DoD: 3 gem 中 1 つ完成、homura が path 依存で動く
       ↓
Phase 15-C (sinatra-homura gem) ← 2 週間  ★本命
  └─ DoD: hello.rb 分割 + 「3 ファイルで動く」examples/ + 自己 dogfood 移植完成
       ↓
Phase 15-D (sequel-d1 gem)                  ← 1.5 週間
  └─ DoD: 3 gem 完成、rubygems.org push 検討フェーズへ
       ↓
(Phase 15-Future) jwt / http gem 化 ← 境界が立ってから
```

### 想定総工数: **5-7 週間**（5 段それぞれ独立に進む。並行余地ほぼなし＝クリティカルパス）

### v1 → v2 で変えた決定一覧

| 項目 | v1 | v2 (採用) | 根拠 |
|---|---|---|---|
| Gem 数 | 5 | **3** | Codex: jwt/http は境界が立っていない patch 束 |
| CPU budget | Phase 15-A 並行 | **Phase 15-Pre 独立** | Codex: クリティカルパスを伸ばすな |
| hello.rb 分割 | Phase 15-A | **Phase 15-C へ移送** | Codex: gem 切り出しとセットの方が境界明確 |
| Phase 15-A の中身 | 4 大トピック | **toolchain 契約抽出のみ** | Codex: 粒度大きすぎ |
| サンプルアプリ | 別リポジトリ | **monorepo `examples/` 同居** | Codex: CI 漂流防止、release cadence 分かれてからで十分 |
| 外部 dogfooder | 探す | **自己 Sinatra アプリ移植** | Codex: 現実的に外部探すより自分で 1 本やる方が早い |
| jwt/http の扱い | Phase 15-D で gem 化 | **Phase 15-Future 候補へ降格** | Codex: 境界が立ってから |

---

## Phase 15 以降の実績 (2026-04-20〜22)

計画段階では想定してなかったが、Phase 15-D 完了後に「gem consumer independence」「セルフホスト docs」「Email 送信」の 3 軸が連続発生して実装完了した。

| Phase | 成果 | PR |
|---|---|---|
| 15-E | `gem build + gem install --local` で independent repo から動く証明 (scaffolder, build CLI, worker.entrypoint codegen) | #19 |
| 16 | `homura.kazu-san.workers.dev/docs/` に Cloudflare-style self-hosted docs site (7 ページ) | #20 |
| 17 | Cloudflare Email Service (`SEND_EMAIL` binding) + `Cloudflare::Email` wrapper + `/debug/mail` + `/docs/email` + 本番実送信 (text + HTML 両方) | #21 |

---

## Phase 17.5 — Auto-Await 構文解析 (ゴミ積み禁止・本命設計)

Created: 2026-04-22
Status: Planning (設計フェーズのみ、実装は別 PR)
Scope: **大規模**（Opal compile pipeline への恒久改修。暫定対応 gem default list 方式は採用しない）

### 背景・動機

現状、Opal 上で Promise を返す呼び出し（Cloudflare bindings 全般、JWT, Sequel, fetch 等）は `.__await__` または ファイル先頭の `# await: method1, method2, ...` magic comment による自動挿入で対応している。

問題:

1. **ユーザーが async メソッド名を知ってリストに書かないといけない**（gem 境界を越えた知識要求）
2. **同名 sync メソッドも誤って await 化される** (`String#sub`, `Array#first` など)
3. **ユーザー定義 async メソッドが毎回 magic comment に追加必要**
4. **homura 内レガシー `__await__` 呼び出しが 51 箇所残存**（`app/app.rb` 8 / `app/helpers/chat_history.rb` 5 / `app/routes/canonical_all.rb` 38）
5. Phase 17 で起きた **`__await__` を route 表に出さざるを得ない問題** も同じ根 (scope 単位で有効になる Opal async の制約)

### ゴール

**ユーザーが `.__await__` も `# await:` magic comment も一切書かず、Cloudflare binding 由来の async chain だけが自動的に async として扱われる** 状態。

同名 sync メソッド（`String#sub`, `Array#first`）には**一切 await が挿入されない**（型推論が receiver の origin で区別する）。

### 非ゴール

- gem default list 方式 (**ゴミ積み、不採用**)。同名 sync 誤検知解消にならないため
- Opal upstream への PR (別 phase、Phase 15-Future)
- 非 Cloudflare async source のサポート (`fiber`, `concurrent-ruby` 等) は後続 phase
- metaprogramming (`env.send(binding_name)` 等) 由来の動的 source 検出

### 設計方針: AST + Flow Analysis

Ruby ソースを Opal に渡す前に **`parser` gem で AST を取得 → Cloudflare binding 起点のデータフロー解析 → 該当 call node にのみ `.__await__` 自動挿入** した Ruby ソースを再出力し、それを Opal に食わせる。

#### Async Source の登録仕組み

gem 側で「これは async source」を `register_async_source` で宣言:

```ruby
# gems/homura-runtime/lib/cloudflare_workers/async_registry.rb
CloudflareWorkers::AsyncRegistry.register_async_source do
  # Class/Module whose public instance methods are all async
  async_class 'Cloudflare::Email'
  async_class 'Cloudflare::D1Database'
  async_class 'Cloudflare::KV'
  async_class 'Cloudflare::R2'
  async_class 'Cloudflare::Queue'
  async_class 'Cloudflare::AI'
  async_class 'Cloudflare::Cache'

  # Factory methods that return async-tainted objects
  async_factory 'Cloudflare::Email', :new
  async_factory 'Sequel', :connect, when_kwarg: { adapter: :d1 }

  # Accessor chains: env['cloudflare.env'].DB, env.SEND_EMAIL, etc.
  async_accessor /^env(\[.+?\])?\.[A-Z_][A-Z0-9_]*$/
end
```

`sinatra-homura` や `sequel-d1` も同様に自身の async source を登録する。

#### Flow Analysis アルゴリズム

1. Ruby ソース parse → AST
2. **tainting pass**: 各変数/式に `async-tainted` フラグを計算
   - `Cloudflare::Email.new(...)` の戻り値 → tainted
   - `env.SEND_EMAIL` → tainted
   - tainted オブジェクトの method call 戻り値 → tainted
   - tainted 変数の代入先 → tainted
   - tainted chain (`a.b.c.d`) 全ノード → tainted
3. **insertion pass**: tainted な call node の直後に `.__await__` を AST レベルで挿入
4. **unparse pass**: AST を Ruby ソースに書き戻す（`unparser` gem or 独自 visitor）

#### パイプライン位置

```
app/app.rb (ユーザーコード、__await__ 無し)
  │
  ▼  bundle exec cloudflare-workers-build 内で
  ▼  1. parse → AST
  ▼  2. Async Registry ロード (全 gem の register_async_source 収集)
  ▼  3. flow analysis → tainted node 集合
  ▼  4. __await__ 自動挿入
  ▼  5. unparse → 変換後 Ruby ソース (build/app.opal.rb)
  │
  ▼  Opal コンパイル (変換後ソースを食わせる)
  ▼
build/app.opal.mjs
```

### 既存 `# await:` magic comment との互換性

- magic comment が書いてあるファイルは **override として尊重**（ユーザーが明示的に指定したものは消さない）
- 書いてなくても flow analysis が推論する
- 診断モード (`CLOUDFLARE_WORKERS_AUTO_AWAIT_DEBUG=1`) で「どの call に await を入れたか」を build log に出力

### 期待される振る舞い (B1-B10)

- [x] **B1**: `gems/homura-runtime/lib/cloudflare_workers/async_registry.rb` 実装（`register_async_source` DSL）
- [x] **B2**: `gems/homura-runtime/lib/cloudflare_workers/auto_await/analyzer.rb` 実装
  - `parser` gem 依存（build-time only、runtime には乗らない）
  - tainting pass + insertion pass + unparse pass
  - **修正済**: ボトムアップ走査（子→親）に変更、`kv.get(key)` 等のawait漏れを解消
- [x] **B3**: `bin/cloudflare-workers-build` 内で auto-await 変換を opal compile 前段に挿入
- [x] **B4**: `sinatra-homura` の `register_async_source` に Sinatra::Base の async extension (JWT) を登録
- [x] **B5**: `sequel-d1` の `register_async_source` に `Sequel::D1::Database` の dataset chain を登録
- [x] **B4.5**: auto-await CLI が `Gem.loaded_specs` を走査し、各 gem の `lib/` 配下から `register_async_source` を含む .rb ファイルを自動検出・require（手動リスト廃止）
- [x] **B6**: homura 既存 `__await__` を削除 (auto 挿入に切替)、`# await:` magic comment もユーザー指定以外は削除
  - **完了**: app/ ソース上の `# await: true` / 手動 `.__await__` は 0 件。
  - **追加対応**: receiver-less async helper（`load_chat_history`, `cache_get` など）と Durable Object handler の `state.storage.get/put/delete` も analyzer が追跡可能になった。
- [x] **B7**: 回帰検証 — `npm test` 全 16 スイート **393/393 pass**
  - **実施済**: 本番 deploy 完了、代表 12 ルートの実機確認、`/debug/mail` 実送信を確認。証跡は `.artifacts/phase17.5/production-verify.log`
  - **追加実施**: `wrangler dev --local --var HOMURA_ENABLE_BINDING_DEMOS:1` で `/demo/do`, `/demo/cache/heavy`, `/test/bindings` を確認。証跡は `.artifacts/phase17.5/gated-routes-verify.log`
- [x] **B8**: `examples/minimal-sinatra-with-email/` 新 example 追加
- [x] **B9**: 診断モード（`--debug` / `CLOUDFLARE_WORKERS_AUTO_AWAIT_DEBUG=1`）
- [x] **B10**: `/docs/auto-await` ページ追加

### Phase 17.5 実装中の発見・修正

- **Analyzer ボトムアップ走査**: トップダウン走査では `@env` が未設定のため `kv.get(key)` 等が await 対象から漏れていた。子→親に修正。
- **`async_factory` vs `taint_return` 競合**: `Sequel.connect` に両方登録され `infer_send_class` で factory が先に評価されていた。`async_factory` を削除。
- **定数スコープ問題**: `# await: true` でファイル全体が async function に包まれると `App.class_eval` 内の定数がトップレベルとして解釈される。`App::JWT_ACCESS_TTL` 等に完全修飾名化。
- **重複 await 問題 (copilot レビュー指摘)**: `db.prepare(sql).all` で `prepare` が `async_method` + `taint_return` の両方に登録されていたため、内外両方に `.__await__` が挿入される可能性があった。`prepare` は JS 上同期的なので `async_method` 登録を削除して解消。
- **`lib/homura_async_sources.rb`**: プロジェクト固有の async source 登録を集約。sequel-d1 gem 内の登録は auto-await CLI の読み込み対象外だったためここに移動。
- **`parser` gem**: auto-await analyzer を build pipeline から利用する都合で runtime dependency のまま維持。

### Phase 17.5 クローズ時メモ（2026-04-22 更新）

1. **証跡の参照先は `/docs/auto-await`**
   - スクリーンショットは `.artifacts/phase17.5/docs-auto-await.png` に保存済み。未存在の `/test/auto-await` ではなくこちらを正とする。
2. **gated routes の再確認コマンド**
   - `npx wrangler dev --local --port 8791 --var HOMURA_ENABLE_BINDING_DEMOS:1`
   - `curl http://127.0.0.1:8791/test/bindings`

### リスク & 対策

| リスク | 対策 |
|---|---|
| `parser` gem の build time 増加 | Ruby ファイル単位で cache、差分のみ再解析 |
| AST→Ruby 逆変換の副作用 (コメント消失、空白変化) | `unparser` 採用 or source_rewriter で元ソースに挿入のみ行う（非破壊パッチ方式） |
| metaprogramming で動的に binding 取り出すユーザー | 推論不能な場合は従来の `.__await__` / `# await:` フォールバックを許容、診断で警告 |
| 誤 taint propagation (`x = env.DB; x = 'foo'` 後の `x.length`) | 変数再代入で taint クリア、SSA ライクな解析に寄せる |
| Opal 側の対応が将来変わる | `async_registry.rb` に Opal version 互換層を置く |

### 想定工数

| Step | 内容 | 工数 |
|------|------|------|
| 0 | 起動準備 + baseline | 0.2d |
| 1 | `parser` gem を build dependency に追加、POC で sample AST 解析 | 1d |
| 2 | AsyncRegistry DSL 設計 + 3 gem への実装 | 2d |
| 3 | Analyzer (tainting + insertion + unparse) | 3d |
| 4 | cloudflare-workers-build への統合 | 1d |
| 5 | homura 51 箇所 `__await__` 削除 + `# await:` magic 削除 | 1d |
| 6 | 回帰検証 (npm test + deploy + 全ルート 200 + Email 実送信) | 1d |
| 7 | 診断モード + build log | 0.5d |
| 8 | `examples/minimal-sinatra-with-email/` 新 example | 0.5d |
| 9 | `/docs/auto-await` 新ページ | 0.5d |
| 10 | REPORT + PR + Copilot 対応 | 1d |
| **合計** | | **約 12 営業日 (2.5 週間)** |

### Phase 17.5 完了後のユーザー体験

Before (現状):
```ruby
# await: get, put, execute, fetch, send, decode, ...

post '/users' do
  db = Sequel.connect(adapter: :d1, d1: env['cloudflare.env'].DB)
  result = db[:users].insert(name: 'foo').__await__
  Cloudflare::Email.new(env.SEND_EMAIL).send(
    to: '...', subject: '...', text: '...'
  ).__await__
  'ok'
end
```

After (Phase 17.5 完了後):
```ruby
post '/users' do
  db = Sequel.connect(adapter: :d1, d1: env['cloudflare.env'].DB)
  result = db[:users].insert(name: 'foo')
  Cloudflare::Email.new(env.SEND_EMAIL).send(
    to: '...', subject: '...', text: '...'
  )
  'ok'
end
```

**素の Sinatra とほぼ同じ見た目**になる。これが「既存 Sinatra ユーザーが違和感なく Workers 化できる」最後のピース。

---

## 後回しメモ

- **15-F** rubygems.org 公開
  - repo 分割は不要。今の構成は **「開発は monorepo / 公開は gemspec 単位」** で固定。
  - **最終ブランド決定 (2026-04-23):**
    - この repo / showcase app の名前は **`homura`**
    - sister mruby/WASI repo の名前は **`hinoko`**
    - **`homura` という gem は出さない**
  - **公開名はこの 4 つで確定**:
    - `opal-homura`
    - `homura-runtime`
    - `sinatra-homura`
    - `sequel-d1`
  - **公開単位と役割**:
    - `opal-homura` — Opal fork。`require: 'opal'` のまま使う
    - `homura-runtime` — core runtime
    - `sinatra-homura` — Sinatra integration
    - `sequel-d1` — D1 / Sequel integration
  - **publish 順**は依存順で固定:
    1. `opal-homura`
    2. `homura-runtime`
    3. `sinatra-homura`
    4. `sequel-d1`
  - **publish 前提条件**:
    - gemspec / README / 同梱 docs / unpack 後 `.gem` artifact に **`homurabi` を残さない**
    - MIT ライセンス明示済み
    - 各 gem の `gem build` は通す
    - repo 全体の検証は `npm test` と `npm run build`
  - **他 AI 向け注意**:
    - ローカル worktree のディレクトリ名が旧名のまま残っていても、それを branding の根拠にしないこと
    - publish 判断は **gemspec 名 / 同梱物 / unpack 後 artifact** で行うこと
    - GitHub repo は **`kazuph/homura`**、mruby 側は **`kazuph/hinoko`**
  - **実 push 直前チェック**:
    - RubyGems の認証 / MFA を確認
    - 既存 version との衝突を確認
    - `gem push` は上の依存順で実行
  - prerelease 運用判断だけは別途残タスク。

---
