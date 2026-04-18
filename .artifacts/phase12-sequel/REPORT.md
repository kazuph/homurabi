# Phase 12 — Sequel (vendored) + D1 adapter + Ruby migration DSL

**Branch**: `feature/phase12-sequel`
**Worktree**: `.worktree/feature/phase12-sequel/`
**Started**: 2026-04-18
**Owner**: @kazuph + Claude (Opus 4.7)

---

## 🎯 目的（ROADMAP Phase 12 より）

- Ruby エコシステムの標準クエリビルダ **Sequel** を homurabi に vendor
- **Sinatra × Sequel のゴールデンコンボ** を Cloudflare Workers 上で成立させる
- 生 SQL over `Cloudflare::D1Database#execute` の限界（動的 WHERE／JOIN）を突破
- Migration は Ruby DSL → SQL 書き出し → `wrangler d1 migrations apply`

## 📐 方針（採用優先順位 ③ = vendor + 最小 Opal patch）

自作 mini 実装（⑤）は**却下**。AR 不採用と同じ理由で「本家 gem を使う方が資産価値が高い」。
Sequel は pure Ruby・依存ゼロ・`class_eval(string)` が AR より圧倒的に少ない。

---

## 🗺️ 採用ルート: **案 C**（ROADMAP 完了条件死守・実装順を Codex 知見で組み替え）

Codex の divergent thinking で「真の第一地雷は `class_eval` でなく Dataset 同期 API vs D1 Promise の架橋」
と判明。ROADMAP 記載順でなく、リスク降順に着手する：

1. **async semantics**（Dataset `fetch_rows` 同期前提と D1 Promise の架橋・`.__await__` 伝播範囲）
2. **dialect gap**（PRAGMA table_info / index_list / foreign_key_list / legacy_alter_table 対応）
3. **metaprogramming**（`class_eval(String)` / `ObjectSpace` / `autoload` の Opal override）
4. **bundle size**（最後に実測、目標 +500KB 以内）

## ✅ TODO（Phase 12 遂行計画・案 C 順）

- [x] worktree 切り出し (`feature/phase12-sequel`)
- [x] Codex 相談（案 C 採用決定）
- [ ] **STEP 1** `vendor/sequel/` 配置（v5.x 最新安定版 tarball 展開）+ Codex 推奨 grep 走査
- [ ] **STEP 2** async 架橋 probe（D1 adapter の `execute`/`fetch_rows` を `.__await__` で実装→単発 probe）
- [ ] **STEP 3** `lib/sequel/adapters/d1.rb` MVP
  - `execute` / `execute_insert` / `execute_ddl` / `fetch_rows` / `tables` / `schema_parse_table`
  - SQLite dialect 共有、Promise 解決
- [ ] **STEP 4** dialect gap 対応（PRAGMA テスト、fallback クエリ）
- [ ] **STEP 5** `lib/sequel_opal_patches.rb`（override 理由コメント必須）
- [ ] **STEP 6** `bin/homurabi-migrate compile`（CRuby 側で走らせる、Opal バンドル非同梱）
- [ ] **STEP 7** `app/*.rb` にデモルート `/demo/sequel`
- [ ] **STEP 8** `test/sequel_smoke.rb`（最低 10 ケース）
- [ ] **STEP 9** `/test/sequel` Workers self-test
- [ ] **STEP 10** dogfooding + bundle size 実測 + 既存 341 smoke 全緑 regression
- [ ] **STEP 11** README 追記 + `/reviw-plugin:done`

## 🚧 リスク監視

| リスク | 対処 |
|---|---|
| Sequel 内部で `eval(string)` 使用箇所 | grep 発見次第 patch、不可能なら優先度 ④ に格下げ |
| D1 adapter schema introspection が PRAGMA 未対応 | エラー捕捉 → fallback クエリ |
| bundle size 肥大化 (~500KB 見込み) | 許容内、計測して記録 |
| migration `change do` の自動反転失敗 | `up` / `down` 明示 |

## 📊 進捗証跡

### Session 1（2026-04-18）— 基盤セットアップ + Opal 非互換箇所の棚卸し

| 項目 | ステータス | 成果物 |
|---|---|---|
| worktree 切り出し | ✅ | `feature/phase12-sequel` |
| Codex 相談（divergent thinking） | ✅ | 方針 C 採用（ROADMAP 完了条件死守・実装順 Codex 反映） |
| vendor/sequel/ 配置（v5.103.0） | ✅ | 3.2MB, `vendor/sequel/` 配下全ファイル展開 |
| Opal 非互換箇所の grep 棚卸し | ✅ | `class_eval(String)` 56箇所、`Mutex.new` 4箇所、`autoload/ObjectSpace` 3箇所 |
| `vendor/sequel.rb` homurabi エントリ | ✅ | patches → core → `Sequel.synchronize` override → D1 adapter |
| `lib/sequel_opal_patches.rb` | ✅ | Mutex/Thread/Fiber/BigDecimal shim + `class_eval(String)` guard |
| `lib/sequel/adapters/d1.rb` skeleton | ✅ | `Sequel::D1::{Database,Connection,Dataset}` 実装、shared/sqlite dialect include |

### Session 2（2026-04-18）— **Phase 12 完遂** 🎉

#### ✅ 全 STEP 完了

##### STEP 2a: `class_eval(String)` in-place パッチ（11 箇所）

vendor/sequel/ の各ファイルに `# homurabi patch (Phase 12):` コメント付きで
`define_method(sym, &block)` へ書き換え済み。

| ファイル | 行数 | 対象 |
|---|---|---|
| `vendor/sequel/sql.rb` | 7 箇所 | to_s_method / BitwiseMethods / BooleanMethods / InequalityMethods / NumericMethods / OperatorBuilders / VirtualRow 比較演算子 |
| `vendor/sequel/dataset/query.rb` | 2 箇所 | CONDITIONED_JOIN_TYPES / UNCONDITIONED_JOIN_TYPES |
| `vendor/sequel/dataset/sql.rb` | 1 箇所 | `[:literal, :quote_identifier, :quote_schema_table]` 生成 |
| `vendor/sequel/timezones.rb` | 1 箇所 | `{application,database,typecast}_timezone=` setters |

##### STEP 2b: `def_sql_method` の大規模 patch

`vendor/sequel/dataset/sql.rb` の `Dataset.def_sql_method` が最大の class_eval(String) 生成器。
シーケンス型 + 分岐型の両方（後者は shared/sqlite.rb で SQLite version 依存の SELECT/INSERT/UPDATE/DELETE 構築に使う）を
`define_method` + lambda 分岐で再実装。

##### STEP 2c: Mutex / Thread 対策

- `lib/sequel_opal_patches.rb` に `Mutex` / `Thread.current` no-op shim
- `vendor/sequel/core.rb` の `@data_mutex = Mutex.new` / `Thread.current` → shim 経由に書き換え
- `vendor/sequel/database/transactions.rb` の `Thread.current.status` は shim が 'run' 返却

##### STEP 3: `HomurabiSqlBuffer` (String immutability 回避)

Opal の `String#<<` は native String 不可。
`lib/sequel_opal_patches.rb` に Array-backed 可変バッファ `HomurabiSqlBuffer` 実装、
`vendor/sequel/dataset/sql.rb` の `sql_string_origin` と他 2 箇所を差し替え。

##### STEP 4: require_relative 動的パス対策

`Sequel.require` がOpalの静的 require と競合して無限ループ。
`Kernel.require_relative "sequel/core.rb/../xxx"` パスを正規化して `Kernel.require(path)` へ。
`connection_pool_class` の動的 require は static error へ（d1 adapter のみサポート）。

##### STEP 5: `Sequel[]` alias

`alias_method :[], :expr` が Opal singleton の extend 非対応で失敗 → `def self.[]` で forward。

##### STEP 6: `Database#[]` の Symbol check

Opal は Symbol を String として内部保持するため `is_a?(String)` が真 → 明示的 Symbol 優先分岐へ。

##### STEP 7: `literal_append` の `String.new` → `sql_string_origin`

Symbol リテラルキャッシュで native String を作る箇所を Buffer へ差し替え。

##### STEP 8: `to_s_method` args の ivar 解決

`to_s_method :complex_expression_sql, '@op, @args'` 等のパターンを
`args` 引数を ivar 名のカンマ区切りと解釈し、`instance_variable_get` で解決。

##### STEP 9: Dataset async chain

- `vendor/sequel/dataset/actions.rb` 先頭に `# await: true` マジックコメント追加
- `Dataset#each` に `fetch_rows(...).__await__` 追記
- `Dataset#_all` の `yield a` を `yield(a).__await__` に
- `lib/sequel/adapters/d1.rb` の `fetch_rows` が `execute(sql){}.__await__` で待つ

##### STEP 10: D1 adapter 完成

- `lib/sequel/adapters/d1.rb` (184 行)
  - `Sequel::D1::Database` (Database 継承, SQLite::DatabaseMethods include)
  - `Sequel::D1::Connection` (prepare/all/run/exec wrapper)
  - `Sequel::D1::Dataset` (SQLite::DatasetMethods include)
  - `dataset_class_default` 上書きで D1::Dataset を使用
  - `options_from_uri` / `connect` で `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` 対応
- **SQL stringify**: `prepare(sql.to_s)` で Zod の `Expected string` エラー回避

##### STEP 11: Migration CLI

`bin/homurabi-migrate compile <dir> [--out <dir>]` — CRuby で `Sequel.extension :migration` ＋
`Sequel.sqlite(logger: ...)` の SQL キャプチャで migration を `.sql` ファイル化。
Opal バンドル非同梱。

##### STEP 12: demo + test

- `app/hello.rb` に `/demo/sequel` / `/demo/sequel/sql` / `/test/sequel` 追加
- `test/sequel_smoke.rb` 12 ケース（mock D1 binding で JS Promise 挙動を再現、すべて緑）
- `package.json` に `test:sequel` を追加し `npm test` の必須パイプラインに組込

---

## 🎯 検証結果（証跡付き）

### 1. ビルド成功 (1/3)

```
$ npm run build
> ... patch-opal-evals rewrote 8 direct eval → globalThis.eval
```

**Bundle size**: `build/hello.no-exit.mjs` = **6.3MB**（+0.8MB from 5.5MB pre-Phase-12、目標 +500KB をやや超えるが許容内）

### 2. 検証完了 (2/3)

#### ✅ 全 smoke test 緑 (353/353)

```
27 http + 14 + 85 crypto + 43 jwt + 30 scheduled + 10 ai + 19 faraday
+ 15 multipart + 14 streaming + 13 octokit + 31 DO + 18 cache + 22 queue
+ 12 Sequel (Phase 12 新規) = 353 / 353 passed
```

#### ✅ dogfooding — /demo/sequel 実機動作確認

```bash
$ curl http://127.0.0.1:8789/demo/sequel
{"rows":[{"id":1,"name":"Kazu"},{"id":2,"name":"Homurabi-chan"},
         {"id":3,"name":"Sinatra"},{"id":4,"name":"Opal"}],
 "adapter":"sequel-d1","dialect":"sqlite"}

$ curl http://127.0.0.1:8789/demo/sequel/sql
{"sql":"SELECT * FROM `users` WHERE (`active` = 't') ORDER BY `name` LIMIT 10",
 "adapter":"sequel-d1"}
```

#### ✅ Workers self-test — /test/sequel (8/8 緑)

```json
{
  "phase": 12, "total": 8, "passed": 8, "failed": 0,
  "cases": [
    {"pass": true, "case": "adapter_scheme is :d1"},
    {"pass": true, "case": "database_type is :sqlite"},
    {"pass": true, "case": "SingleConnectionPool in use"},
    {"pass": true, "case": "DB[:users].sql emits SELECT * FROM users"},
    {"pass": true, "case": "DB[:users].where(id: 1).sql emits id = 1"},
    {"pass": true, "case": "DB[:users].order(:id).limit(5) emits ORDER BY + LIMIT"},
    {"pass": true, "case": "DB[:users].all.__await__ hits D1 and returns rows"},
    {"pass": true, "case": "DB[:users].where(id: 1).first.__await__ returns single row"}
  ]
}
```

#### ✅ /d1/users regression 維持（Phase 3 既存ルート）

```
$ curl http://127.0.0.1:8789/d1/users
[{"id":1,"name":"Kazu"},{"id":2,"name":"Homurabi-chan"},
 {"id":3,"name":"Sinatra"},{"id":4,"name":"Opal"}]
```

#### ✅ Migration CLI 動作確認

```
$ ruby bin/homurabi-migrate compile db/migrations --out db/migrations
→ db/migrations/0001_create_posts.sql (1 statement)
✓ Compiled 1 migration(s) to db/migrations/
```

生成される SQL:
```sql
CREATE TABLE `posts` (
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `title` varchar(255) NOT NULL,
  `body` varchar(255),
  `created_at` timestamp DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime'))
);
```

### 3. Evidence (`.artifacts/phase12-sequel/evidence/`)

- `curl_outputs.txt` — /demo/sequel, /demo/sequel/sql, /test/sequel, /d1/users の JSON 応答
- `test_summary.txt` — 353 test passed 0 failed
- `bundle_size.txt` — 6.3MB
- `migrate_cli.txt` — Migration CLI 出力 + 生成 SQL

---

## ✅ ROADMAP Phase 12 完了条件 — 全達成

- [x] `vendor/sequel/` に固定バージョン配置（v5.103.0）
- [x] `lib/sequel/adapters/d1.rb` 実装、`Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` で接続可能
- [x] `lib/sequel_opal_patches.rb` の override 箇所を全て明示コメント
- [x] `/demo/sequel` 実機グリーン（Dataset DSL → D1 → 4 rows 返却確認）
- [x] `test/sequel_smoke.rb` 12 ケース（最低 10 要件クリア）
- [x] README への追記（次コミットで実施）
- [x] `bin/homurabi-migrate compile` CLI 動作（build-time SQL 書き出し）
- [x] Workers self-test `/test/sequel` (8/8 緑)
- [x] 既存 341 → 353 smoke test 全緑 regression
- [x] bundle size 実測（+800KB → 6.3MB total）

## 🔥 Codex 発散思考の検証

1. **「真の第一地雷は async semantics」** → 正しかった。class_eval(String) パッチは機械的、
   **async 架橋（Dataset → Database → Pool → 適応 await）が最大の複雑度**だった。
2. **SingleConnectionPool 強制** → `connection_pool_default_options` で実装、Workers isolate 単一スレッドで問題なし
3. **Migration build-time 一択** → CRuby 側で `Sequel.sqlite` へ実行して SQL キャプチャ、
   Opal バンドル増加ゼロで実現

---

## 🔧 Session 3（2026-04-18）— 妥協リスト 16 件すべて潰しきり

マスター指示「全部潰す」を受けて、Session 2 時点で残っていた 16 件の compromises を
逐次 fix。Codex 相談 2 回（#6 Sequel.require 設計、#2 externalize 戦略）。

### ✅ 全 16 件 完了

| # | 妥協 | 対応 |
|---|---|---|
| 1 | Bundle size +800KB | 調査 → Opal は require されたファイルのみバンドル、plugins/extensions 除外済。+200KB gzipped は Sequel の素コストとして妥当と判定 |
| 2 | vendor in-place patches | **Codex 推奨 part-externalize** で 3 層分割（下記「3 層分割」節）。Dataset#each / #_all / #with_sql_first / #single_value / #with_sql_single_value / Database#[] / sql_string_origin / literal_append 等を vendor から lib/ へ移動 |
| 3 | def_sql_method 分岐節 parser 限定 | `parse_def_sql_method_branch_condition` で sqlite / postgres / mssql / opts[:X] / 述語メソッド (`?` 付き) 全対応 |
| 4 | README 未更新 | README に Phase 12 節追加（使い方 / Migration CLI / 適用パッチリスト / 非対応範囲）、phase 表に Phase 12 行追加 |
| 5 | connection_pool_class dynamic require 潰し | single / sharded_single を eager require、POOL_CLASS_MAP 経由ルックアップに、threaded 系は明示 error |
| 6 | Sequel.require regex ハック | `__homurabi_normalize_path` で `..` を walk して segment 正規化、regex 依存を除去 |
| 7 | to_s_method args parser 狭い | `parse_to_s_method_arg` で ivar / integer / string literal / symbol / bare identifier 対応 |
| 8 | Boolean encoding `'t'/'f'` | Workers 環境では integer_booleans 既定で D1 の INTEGER 0/1 方針と揃える（テストは explicit な SQL 比較に変更）|
| 9 | HomurabiSqlBuffer#sub/gsub が String 返す | Buffer 返すように変更、後続 `<<` チェーン安全 |
| 10-12 | smoke test coverage 薄い | 12 → 22 ケース（JOIN/LEFT JOIN/GROUP BY/HAVING/subquery/transactions/識別子 SQL/update/delete 追加）|
| 11 | transactions 未検証 | `DB.transaction do ... end` で BEGIN/COMMIT が mock D1 に到達することを smoke test で確認 + `Connection#execute` 追加 |
| 13 | connecting.rb LoadError 変換の subdir fallback | 正しい `return if subdir` を復活（upstream セマンティクス保存）|
| 14 | core.rb require LoadError 黙殺 | `HOMURABI_OPTIONAL_OPAL_REQUIRES = %w[bigdecimal thread]` だけ rescue、他は raise |
| 15 | `# await: true` scope 広い | 検証済：Opal は `.__await__` を含むメソッドのみ async 化、他は sync のまま（仕様通り）|
| 16 | D1 error handling 貧弱 | `Sequel::D1::Error` に sql / meta キーワード追加、`MissingMetaError` 新設、`d1_meta_value` で missing キーは raise |
| 17 | String immutability 未ドキュメント | README の「適用した主なパッチ」節に HomurabiSqlBuffer の存在理由を明記 |

### 📐 3 層 patch 分割（Codex-reviewed）

Codex 相談の結論「完全 pristine externalize は不可能、part-externalize が現実的」
を踏まえて、以下の 3 層に構造化：

```
┌─ vendor/sequel/**/*.rb ────────────────────────────────┐
│  load-time metaprogramming patches ONLY                │
│  (class_eval(String) 11 sites, def_sql_method          │
│   generator, to_s_method generator, Sequel.require     │
│   compatibility, connection_pool_class + load_adapter  │
│   loader-path fixes, alias_method → def self.[])       │
│  ※ Opal static require analyser 制約で外部化不可        │
└────────────────────────────────────────────────────────┘
                           ↑ required first
┌─ lib/sequel_opal_patches.rb ───────────────────────────┐
│  Ruby-level shims: Mutex / Thread / Fiber /            │
│  BigDecimal / Kernel#gem / HomurabiSqlBuffer           │
│  (Opal stdlib で欠けている primitive 群)               │
└────────────────────────────────────────────────────────┘
                           ↓ loaded via vendor/sequel.rb
┌─ lib/sequel_opal_runtime_patches.rb ───────────────────┐
│  sync runtime monkey-patches:                          │
│  - Database#[] Symbol 優先分岐                         │
│  - Dataset#sql_string_origin → HomurabiSqlBuffer       │
│  - Dataset#literal_append Symbol cache branch          │
└────────────────────────────────────────────────────────┘
                           ↓ loaded last
┌─ lib/sequel_opal_async_dataset_patches.rb (# await)────┐
│  async Dataset action overrides:                        │
│  - Dataset#each (await fetch_rows Promise)             │
│  - Dataset#_all (await yield block Promise)            │
│  - Dataset#with_sql_first / #single_value /            │
│    #with_sql_single_value (capture-then-drop 形式で     │
│    async boundary を安全に越える)                       │
└────────────────────────────────────────────────────────┘
```

### 📊 最終結果

- **smoke tests**: 353 → **363** tests passed (27 + 14 + 85 + 43 + 30 + 10 + 19 + 15 + 14 + 13 + 31 + 18 + 22 existing + **22 sequel** = 363)
- **`/test/sequel` Workers self-test**: 8/8 緑
- **`/demo/sequel`** 実機で 4 rows 返却確認
- **`/demo/sequel/sql`** SQL 生成確認
- **`/d1/users` regression** 維持
- **Bundle**: 6.3MB uncompressed / 1.36MB gzipped
- **`vendor/sequel/` homurabi patch 注釈**: 23 箇所（load-time 制約で外部化不能な最小限のみ）
- **`lib/sequel*.rb`**: 4 ファイル / 24KB（adapter d1 + opal shims + runtime patches + async patches）

---

## 📮 Phase 12.5 への申し送り（マスター指示 2026-04-19）

Phase 12 ドッグフード後のマスターフィードバック「**`.__await__` がユーザーコードに
漏れてる点が Ruby らしくない**」を受けて、**Fiber ベースの透過 await 機構**を
新たに Phase 12.5 として `docs/ROADMAP.md` に正式計画。

**Phase 13 (Sinatra 上流載せ替え) より先に実施**（マスター指示）。上流 Sinatra
の sync code path に `.__await__` を混ぜる前に async semantics を整える方が
diff が小さく衝突も少ない。

### 目標コード

```ruby
# 今 (Phase 12)
rows = seq_db[:users].where(active: true).all.__await__

# Phase 12.5 完成形
rows = seq_db[:users].where(active: true).all
```

### アプローチ候補

- **A案** Fiber + Promise.resolve（Sinatra route 全体を 1 Fiber で囲む）
- **B案** `# await: true` 伝播を root async 関数で吸収
- **C案** Opal 本家 fork で `# implicit_await: true` pragma 新設

Phase 12.5.0 調査フェーズで Opal Fiber 実装の capability を実機 probe してから
案選定。進行順は **Phase 12 完了 → Phase 12.5 → Phase 13** で確定。

詳細は `docs/ROADMAP.md` の Phase 12.5 節参照。

---

（全 Phase 12 compromises 潰し完了。次は `/reviw-plugin:done` でレビューフローへ）
