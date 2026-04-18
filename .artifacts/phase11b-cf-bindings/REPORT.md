# Phase 11B — Cloudflare native bindings 基礎固めパック

- **Branch**: feature/phase11b-cf-bindings
- **Base**: main (6e55674, Phase 6-10 shipped)
- **Status**: ✅ implementation + wrangler dev E2E complete, ready for PR

## スコープ

Cloudflare Workers のネイティブ binding 3 点を **Phase 3 の D1/KV/R2 と同じ
"Ruby から backtick 無しで使える" レベル** まで仕上げる:

1. **Durable Objects** — `Cloudflare::DurableObjectNamespace` / `Stub` /
   `Storage` + `Cloudflare::DurableObject.define 'ClassName' do |state, req| ... end`
   で Ruby 側にハンドラ定義 DSL。
2. **Cache API** — `Cloudflare::Cache.default` (+ named cache via `.open`)
   with `match` / `put` / `delete`. Sinatra ヘルパ `cache_get(key, ttl:) { ... }`
   で match → put → miss/hit を一発処理。
3. **Queues** — `Cloudflare::Queue#send` / `#send_batch` プロデューサ +
   `consume_queue 'name' do |batch| ... end` 消費 DSL。`src/worker.mjs#queue`
   が `globalThis.__HOMURABI_QUEUE_DISPATCH__` 経由で Ruby にルーティング。

WebSockets / Named cache 永続化 / Queue DLQ は次フェーズ以降に後送 (本 PR では
production safety のため wrangler.toml から DLQ 設定を外し、DOC として README
に記載)。

## TODO

- [x] `.artifacts/phase11b-cf-bindings/REPORT.md` 初期化
- [x] Durable Objects ラッパ (`lib/cloudflare_workers/durable_object.rb`) + `/demo/do` counter
- [x] Cache API ラッパ (`lib/cloudflare_workers/cache.rb`) + `/demo/cache/heavy`
- [x] Queues binding (`lib/cloudflare_workers/queue.rb`) + `consume_queue` DSL + `/api/enqueue`
- [x] smoke tests (DO 22 / Cache 14 / Queue 20 = 56 ケース)
- [x] `/test/bindings` self-test エンドポイント (全 3 ケース緑)
- [x] `POST /test/queue/fire` 手動発火フォールバック
- [x] wrangler dev 実機検証 (DO hit count 1→4、Cache MISS/HIT、Queue auto consume)
- [x] README に「Cloudflare native bindings (Phase 11B)」節追加 + Phase 11B 行追加
- [x] 既存テスト 209/209 緑維持 → Phase 11B 追加後 265/265 緑
- [ ] commit / push / PR
- [ ] Copilot レビュー全件対応
- [ ] CLEAN / MERGEABLE まで完了（マージは部長/マスター手動）

## 追加ファイル

- `lib/cloudflare_workers/durable_object.rb` (DO ラッパ + handler DSL)
- `lib/cloudflare_workers/cache.rb`           (Cache API ラッパ)
- `lib/cloudflare_workers/queue.rb`            (Queue producer + consumer + QueueContext)
- `lib/sinatra/queue.rb`                       (Sinatra::Queue: `consume_queue` DSL)
- `test/do_smoke.rb`                           (22 ケース)
- `test/cache_smoke.rb`                        (14 ケース)
- `test/queue_smoke.rb`                        (20 ケース)

## 修正ファイル

- `lib/cloudflare_workers.rb`  — 新 wrapper を require、env['cloudflare.DO_COUNTER'] / env['cloudflare.QUEUE_JOBS'] を公開
- `src/worker.mjs`             — `async queue(batch, env, ctx)` + `export class HomurabiCounterDO` 追加
- `app/hello.rb`               — `binding_demos_enabled?` / `do_counter` / `cache` / `jobs_queue` / `cache_get` ヘルパ、`/demo/do` `/demo/cache/heavy` `/api/enqueue` `/demo/queue/status` `/test/bindings` `/test/queue/fire` ルート追加、`Cloudflare::DurableObject.define('HomurabiCounterDO')` + `consume_queue 'homurabi-jobs'` 登録
- `wrangler.toml`              — `HOMURABI_ENABLE_BINDING_DEMOS`、`[[durable_objects.bindings]]`、`[[migrations]]`、`[[queues.producers]]`、`[[queues.consumers]]`
- `package.json`               — `test:do` `test:cache` `test:queue` npm script 追加、`test` に連鎖
- `README.md`                  — Phase 11B 節と phases テーブル行

## テスト結果 (npm test)

```
27 tests, 27 passed, 0 failed   # smoke
14 tests, 14 passed, 0 failed   # http
85 tests, 85 passed, 0 failed   # crypto
43 tests, 43 passed, 0 failed   # jwt
30 tests, 30 passed, 0 failed   # scheduled
10 tests, 10 passed, 0 failed   # ai
22 tests, 22 passed, 0 failed   # do     ← 新規
14 tests, 14 passed, 0 failed   # cache  ← 新規
20 tests, 20 passed, 0 failed   # queue  ← 新規
───────────────────────────────
全 265 ケース / 既存 209 維持 / 新規 56 追加
```

## wrangler dev 実機検証エビデンス

詳細な生ログは `.artifacts/phase11b-cf-bindings/e2e-evidence.txt` に収録。
サマリ:

### DurableObject counter (同一 DO instance、storage 永続)

```
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=reset' → {"reset":true, "do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=inc'   → {"count":1, "previous":0, "do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=inc'   → {"count":2, "previous":1, "do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=inc'   → {"count":3, "previous":2, "do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=inc'   → {"count":4, "previous":3, "do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=peek'  → {"count":4, "do_id":"2ce054..."}
```

DO id (`2ce054...`) が全呼び出しで同一 → 正しく同じ DO インスタンスに
routing されている。

### Cache API (MISS vs HIT の体感差)

```
# 初回 = MISS (PBKDF2 5万ループ)
{"derived_hex":"6ac25e00bf04...", "cache":"MISS", "elapsed_ms":6, ...}

# 同一 URL 2回目 = HIT (derived_hex が同じ → キャッシュから返却)
{"derived_hex":"6ac25e00bf04...", "cache":"HIT", "elapsed_ms":1, ...}
```

同じ `derived_hex` が返る → 再計算ではなくキャッシュヒット。elapsed_ms も
6ms → 1ms に短縮。

### Queue producer + auto consumer (miniflare 3 local emulator)

```
$ curl -s -X POST -d '{"task":"alpha"}' http://127.0.0.1:8787/api/enqueue
{"enqueued":true, "queue":"homurabi-jobs", "payload":{"task":"alpha"}}
$ curl -s -X POST -d '{"task":"beta"}'  http://127.0.0.1:8787/api/enqueue  → {"enqueued":true, ...}
$ curl -s -X POST -d '{"task":"gamma"}' http://127.0.0.1:8787/api/enqueue  → {"enqueued":true, ...}
$ sleep 3   # max_batch_timeout=2, max_batch_size=3
$ curl http://127.0.0.1:8787/demo/queue/status
{"queue":"homurabi-jobs", "count":3, "recent":[
  {"id":"cabc5a...","body":{"task":"gamma"},"batch_index":0,"consumed_at":1776462182},
  {"id":"819052...","body":{"task":"beta"}, "batch_index":1,"consumed_at":1776462182},
  {"id":"...",      "body":{"task":"alpha"},"batch_index":2,"consumed_at":1776462182}
]}
```

miniflare が自動で batch を切って `queue()` export を呼び出し、Ruby 側の
`consume_queue 'homurabi-jobs' do |batch| ... end` ブロックが走って KV に
記録 → `/demo/queue/status` で読み戻せる、エンドツーエンドの round-trip が
確認できた。

### /test/bindings (Workers self-test)

```
{"passed":3, "failed":0, "total":3, "cases":[
  {"case":"DurableObject counter inc/peek/reset round-trip",  "pass":true},
  {"case":"Cache API match after put returns same body",      "pass":true},
  {"case":"Queue producer send() returns without error",       "pass":true}
]}
```

## Max-effort 追加パック (初回 PR 後)

ユーザー指示「費用発生無し / 本家 PR 無しの制約で工数で潰せる妥協全部潰して」を受けて、
初回 Phase 11B PR の self-review で挙げた 9 点の deferred item のうち **再現可能な 8 点を全部対処**。
残 1 点（v2 migration）は「そもそも v2 クラスが無い」ため物理的に対処不能。

### 追加実装

- **DurableObject WebSocket (Hibernation API)**
  - `Cloudflare::DurableObject.define_web_socket_handlers(class, on_message:, on_close:, on_error:)`
  - `DurableObjectState#accept_web_socket` / `#web_sockets(tag:)`
  - `globalThis.__HOMURABI_DO_WS_MESSAGE__` / `_CLOSE__` / `_ERROR__` dispatcher hooks
  - `src/worker.mjs` の `HomurabiCounterDO` に `fetch(Upgrade: websocket)` → 101 + WebSocketPair、
    `webSocketMessage/Close/Error` メソッドを生やし Ruby dispatcher に forward
  - `Cloudflare::RawResponse` ラッパ追加 — Sinatra ルートが 101 upgrade Response を `.webSocket`
    プロパティごとパススルーするためのブリッジ。`Rack::Handler::CloudflareWorkers#build_js_response`
    の `$$class.$$name === 'RawResponse'` 検出 + 中身の JS Response 直接返却分岐。
  - 実機検証: Node `ws` client × 3 frames → "echo:hello-N count=N" 3 件 echo + close 1000 + HTTP peek
    で count=3 永続確認
- **Named Cache** — `/demo/cache/named?namespace=X&key=Y` + 2 namespace 独立 smoke test
- **Cache TTL expiry** — 時間制御可能な fake Cache で post-expiry MISS を assert
- **DLQ local flow** — wrangler.toml に `dead_letter_queue` + DLQ 側 consumer、`/demo/queue/force-dlq`
  + `/demo/queue/dlq-status`、miniflare local で `fail:true` → retry → DLQ 移動 → KV 記録を実機確認
- **Queue send_batch 100 件** — 順序保存 + 件数一致 smoke test
- **DO `blockConcurrencyWhile`** — fake mutex でシリアライズ動作の 3 ケース smoke test
- **Copilot review 2 件 (round 2)** — `request_to_js` docstring-vs-impl 整合 + `cache_get` TTL > 0 validation
- **#9 Opal multi-line backtick audit** — `http.rb` / `ai.rb` に guard-rail コメント追加

### miniflare Queue stall root-cause (調査のみ)

`node_modules/miniflare/dist/src/workers/queues/broker.worker.js` を直接読んだ結論:

- `DEFAULT_BATCH_TIMEOUT = 1` 秒 (override で `max_batch_timeout` 秒)
- `#ensurePendingFlush` が単一 `setTimeout` タイマーを立て、batch が満タンなら即 flush
- 既に pendingFlush ありで `messages.length < batchSize` なら、新タイマーを立てず既存タイマーを待つ
- QueueBroker 自体が Durable Object なので wrangler restart 直後は **DO cold-start 遅延** が
  max_batch_timeout に上乗せされ、単一メッセージで 10+ 秒遅れることがある
- ワークアラウンド: `max_batch_size=3` / `max_batch_timeout=2` に下げた + `POST /test/queue/fire`
  で手動 dispatcher invoke の fallback 提供

wrangler 本体のバグではなく、miniflare 3 の DO コールドスタート挙動。wrangler 4.83 にしても同じ
はず (未検証、upgrade 指示なしのため)。

### 残タスク (物理的に対処不能 1 点)

- **DO migrations v2 リネーム** — 今 DO クラスが 1 個だけ (`HomurabiCounterDO`) なので `v1` 固定で
  足りる。2 個目のクラスを追加するフェーズで自然に解決。

## 特記事項

### 1. Opal の multi-line backtick quirk (今回の最大のハマりどころ)

`async function () { ... }()` を **複数行の backtick** で書くと、Opal コンパイラは
"raw statement" として扱い、返り値の Promise を捨てる。結果: 呼び出し側の
`__await__` が `undefined` を待ってしまい、`await cache.put(...)` が silent
に `put` 前にすり抜ける (miniflare Cache に書き込めているが Promise が待たれて
いないため、後続の `match` はまだ put 完了していない → `null` が返る / また
は同 request 内で match が空で帰ってくる) 。

**対策**: Cache / Queue / DO の async 呼び出しは **single-line IIFE**
パターンに統一した。可読性のため改行したい箇所はあるが、Opal が
"expression" として扱うには 1 行に収める必要がある。各 wrapper の当該
箇所にコメントで根拠を書いた。

同じ quirk は Phase 9 の `Cloudflare::Scheduled.install_dispatcher` にも
既に存在していた (コメント済み) ので、前例踏襲で統一。

### 2. Opal の `nil?` が JS object では使えない

`env['cloudflare.env']` は生の JS object。そこで `.nil?` を呼ぶと
`TypeError: $nil? is not a function` で落ちる。Phase 10 の `ai_binding?`
が既にこの落とし穴のコメントを残していたのでそれを踏襲。`available?` 系
helper は JS 側で `(x != null && x !== undefined && x !== Opal.nil)` を
見るように統一した。

### 3. miniflare 3 Queue consumer の挙動

wrangler 3.114 + miniflare 3 では `[[queues.consumers]]` は動くが、wrangler
プロセスを頻繁に restart しているとたまに consumer の auto-dispatch が
silent に stall する (同一 worker の producer → consumer が成立するのに数十秒
待っても flush が来ない)。最終的に `max_batch_size = 3`, `max_batch_timeout = 2`
にすると安定して flush。開発時の fallback として `POST /test/queue/fire` で
`Cloudflare::QueueConsumer.dispatch_js` を合成バッチで呼べるようにしてある。

### 4. production safety

- 全 demo route は `HOMURABI_ENABLE_BINDING_DEMOS=1` で default deny。
- Queues の DLQ (`homurabi-jobs-dlq`) は wrangler.toml から外した。local で
  unknown DLQ を指すと consumer flush が stall する現象が再現したため。
  production 配置時に `wrangler queues create homurabi-jobs-dlq` して
  `dead_letter_queue` エントリを足すだけ (README に手順記載)。
- DO migrations (`[[migrations]] tag = "v1" new_sqlite_classes = ["HomurabiCounterDO"]`)
  は初回 deploy 時に wrangler がプロンプトする。

### 5. 競合ファイル

Phase 11A と Phase 11B が並列進行中。共通変更対象:
- `src/worker.mjs`            : 11A が fetch() を、11B が queue + HomurabiCounterDO export を追加
- `lib/cloudflare_workers.rb` : 11A は HTTP 系を、11B は binding 系を追加
- `app/hello.rb`              : 11A は /demo/http*、11B は /demo/do* /demo/cache* /api/enqueue
- `README.md` / `package.json`/ `wrangler.toml`

11B はネイティブ binding 寄りの変更のみに絞り、HTTP (Faraday/multipart/streaming)
には触れていない。マージ時のコンフリクトは機械的に解消できる想定。
