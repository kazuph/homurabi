---
name: opal-workers-gem-adoption
description: homura (Opal-compiled Ruby on Cloudflare Workers) に Ruby gem / pure-Ruby ライブラリを新規採用する際の判定基準と前例集。「この gem 入れていい？」「この util 書き起こすべき？」と迷ったときに参照する。採用 NG 判例の再発防止も兼ねる。
---

# Opal-on-Workers ライブラリ採用ガイド

homura のランタイムは **Opal でコンパイル→ Cloudflare Workers 上で実行** の 2 段構え。
CRuby で動くからといって Workers で動くとは限らない。このスキルは Phase 3〜11B の
実装で何度も刺された制約を、採用判定チェックリストとしてまとめたもの。

## TL;DR

- **必要条件**: Pure Ruby / C 拡張ゼロ / `eval` 系を実行時に呼ばない / `fork`・`Thread` なし /
  ファイル I/O と Socket なし / Opal の String immutability 対応
- **望ましい条件**: 依存ゼロ or vendor 済み / バンドル追加 500KB 以下 / MIT/Apache-2.0
- **前例**: `janbiedermann/sinatra` (fork vendored)、`ruby-jwt` (vendored + async patch)、
  自作 `lib/homura_markdown.rb` (~200行、zero-dep 目標)

## 必須条件（破ると物理的に動かない）

| # | 条件 | 破れた時のエラー |
|---|---|---|
| 1 | Pure Ruby（C 拡張ゼロ） | Opal ビルド時に native gem 見つからない |
| 2 | `eval` / `instance_eval(String)` / `module_eval(String)` / `binding.eval` を**実行時に使わない**。ERB 自動生成もこれに抵触するため `bin/compile-erb` で AOT 変換している | Workers が `Code generation from strings disallowed for this context` |
| 3 | `fork` / `Thread.new` / `Process.*` ゼロ | Workers は単一 isolate — 即 crash |
| 4 | File / Socket / TCPSocket / net 直 I/O なし（`fetch` のみ経由） | `File.open undefined` / TypeError |
| 5 | String を `<<` でミューテートしない（`@buffer = @buffer + str` で置き換える） | `frozen: can't modify string` |
| 6 | Regex が JS 正規表現エンジン互換 | silent wrong match（気づきにくい） |
| 7 | 実行時に Opal 同梱外の stdlib を touch しない | `LoadError` |

### #2 の具体例（ERB 本体は Workers で動かない）

- 標準 ERB は `eval` で template を Ruby code に変換→実行する。Workers 禁止。
- homura は `bin/compile-erb` で AOT 変換して `HomuraTemplates.register(:name) { |_| ... }` の Proc 群にして回避。
- **ERB 系/テンプレ系ライブラリを追加するときはこの制約に注意**。Haml / Slim / Liquid は動的 eval 使うので NG 候補。

### #6 の Regex 落とし穴

- Ruby の Onigmo は `\p{Hiragana}` 等の Unicode property をサポートするが Opal compile 後は JS regex 側の挙動になる
- 後読み `(?<=...)` は ES2018+ なので新しめの Workers ではOK、古い runtime では注意
- `\A` `\z` は安全（JS `^$` と同義扱い）
- `#{1,6}` のような **文字リテラル `#` + 量指定子** は Ruby 側で interpolation と誤認される（`[#]{1,6}` と書く）

## 望ましい条件（保守運用の楽さ）

- **バンドル追加で ~500KB 超えると** ビルド時間 & cold start に効く
  - 理想: 50-200KB 以内
  - 参考: `ruby-jwt` vendored 丸ごとで数百 KB、ビルド成果物 `build/hello.no-exit.mjs` ~6MB
- **依存ゼロか vendored 済み**: 依存があれば先に Opal 同梱で動くか確認（`strscan` / `rexml` / `set` などは要個別チェック）
- **同期 API だけならベスト**: I/O するなら `__await__` で包めるか、`# await: true` ファイルに分離する
- **Ruby 3.x 前提**（Opal 1.8+ は 3.x ベース）
- **テストが pure Ruby で書かれてる**: `test/*_smoke.rb` に流用できると早い

## ライセンス / リリース面

- **MIT / Apache-2.0** が無難 — 再同梱・vendor 改変が前提になる場面が多い（例: JWT は vendored patch してる）
- Semver 厳守してるかも重要。本家追従で差分当て直す際の負担が全然違う

## 採用判定フローチャート

```
この gem を採用していい？
 ├─ C 拡張あり？ ──── YES → NG (ChaCha20-Poly1305 が Phase 7 で deferred になった典型例)
 ├─ eval 系を実行時に呼ぶ？ ─ YES → NG か、AOT 変換 + 書き換えできるか検討
 ├─ fork / Thread / Socket ─ YES → NG
 ├─ Pure Ruby で依存ゼロ？ ── YES → 試験 require → smoke test → 採用
 └─ 依存あり？ ─────────────── 依存側も同様にチェック、全部通れば vendor 同梱
```

## 採用パターン（既存前例 & 推奨レシピ）

### パターン A: vendor 同梱 + 必要最小限 patch
- 例: `ruby-jwt` (v2.9.3 を `vendor/jwt/` に丸ごと、`__await__` 対応 patch 適用)
- 向いてるケース: 本家活発 / サイズ中〜大 / 機能削りたくない
- リスク: 本家更新追従の手間（ただし jwt は 2.9.3 から動いてないので現状低リスク）

### パターン B: 自作 mini 実装
- 例: `lib/homura_markdown.rb` (200 行、Rack::Utils.escape_html 依存だけ)
- 向いてるケース: 機能サブセットで十分 / 本家が巨大すぎる / プロジェクト固有の制約適用したい
- リスク: エッジケース拾いこぼし → smoke test で補う

### パターン C: vendored + Opal 特化 fork
- 例: `janbiedermann/sinatra` (Opal 対応 fork を `vendor/sinatra/` に)
- 向いてるケース: 本家が Opal 非対応 / 大規模書き換え必要
- リスク: 上流 Sinatra の更新を取り込めない（homura は意図的に vendored）

## 超軽量 gem を自作する場合のディレクトリ雛形

```
foo_gem/
├── lib/foo_gem.rb              # 本体（200 行以内を目標）
├── lib/foo_gem/version.rb
├── test/test_foo_gem.rb        # CRuby 実行できる minitest
├── spec/fixtures/*.{md,json}   # ゴールデンファイル
├── foo_gem.gemspec             # 依存ゼロ宣言
├── README.md                   # 制約（非対応機能、前提実行環境）明記
└── .github/workflows/ci.yml    # Ruby 3.1-3.4 の matrix
```

### homura に取り込む手順

1. `vendor/foo_gem/lib/foo_gem.rb` にコピー or `git submodule add vendor/foo_gem`
2. `package.json` の `build:opal` が `-I vendor` 付きで動くのを確認
3. `app/hello.rb` 先頭に `require 'foo_gem'`
4. `test/foo_smoke.rb` 追加 → `package.json` に `test:foo` script 登録
5. README の「Upstream policy — patches stay vendored」節に追記

## 既存採用済み一覧（2026-04 時点）

| ライブラリ | 形態 | サイズ感 | 用途 |
|---|---|---|---|
| `janbiedermann/sinatra` | vendor fork | 大 | Rack ベース Web フレームワーク |
| `rack`, `mustermann` | vendor | 中 | Sinatra 依存 |
| `ruby-jwt` | vendor + patch | 中 (~2.5k 行) | JWT encode/decode |
| `cgi`, `digest`, `net` (shims) | vendor patches | 小 | stdlib shim |
| `lib/homura_markdown.rb` | 自作 | 極小 (~200 行) | Markdown → HTML 変換 |
| `lib/cloudflare_workers/*.rb` | 自作 | 中 | D1/KV/R2/AI/Cache/Queue/DO wrapper |

## 採用判定で迷ったら

1. **`npm run build` で Opal がビルド通る？** (native gem なら即 NG)
2. **`npm test` の smoke suite 追加 → 全部 pass？** (runtime エラー検出)
3. **`wrangler dev` で実機 200 OK 返ってくる？** (Workers ランタイム制約)
4. **バンドルサイズ増分 `ls -la build/hello.no-exit.mjs` が受け入れ範囲？**

4 つ全部 OK なら採用 GO。

## 不採用にした先例（ロードマップから）

- **kramdown**: pure Ruby だけど 5k 行 + strscan/rexml 依存でデカい → 自作 mini で代替
- **commonmarker / redcarpet / rdiscount**: C 拡張 → 物理的に NG
- **Markdown レンダラ (当初 kramdown)**: クライアント marked.js で十分だった（README ロードマップ記載）
- **QR コード生成 (rqrcode)**: クライアント JS で完結
- **PDF 生成 (prawn)**: バンドル肥大化 + Worker CPU 制限 + PDF.js で代替可
- **Liquid テンプレ**: ERB プリコンパイルで足りる
- **シンタックスハイライタ (rouge)**: クライアント highlight.js/shiki で十分
- **ActiveRecord**: D1 用 adapter の工数対効果低（Sequel の方が筋が良いが Phase 11+）
- **Nokogiri**: libxml2 ネイティブ依存で物理的に不可
- **ChaCha20-Poly1305**: Web Crypto 標準にも nodejs_compat にもなし（Phase 7 deferred）

## Phase 進化でわかった "これはイケる" パターン

- **wrapper 作成パターン** (Phase 3/6/7/9/10/11B): JS binding 側の機能を Ruby から呼べるように backtick x-string で薄く包む。single-line IIFE が安全（multi-line は Promise を silent drop する落とし穴あり — 詳細は `lib/cloudflare_workers/cache.rb#put` のコメント）
- **dispatcher 登録パターン** (Phase 9/11B): `globalThis.__HOMURA_*_DISPATCH__` に async function を install、`src/worker.mjs` から forward
- **AOT 変換パターン** (ERB): 実行時 `eval` を回避するため、ビルド時に Ruby コードへ変換

迷ったら既存 wrapper (`lib/cloudflare_workers/*.rb`) と `lib/homura_markdown.rb` を読んで真似る。
