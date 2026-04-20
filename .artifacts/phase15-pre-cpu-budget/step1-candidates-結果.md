# Step 1 — require 辺切断の結果

## 1) `corelib/irb`（`vendor/opal-gem/opal/opal.rb`）

- **変更**: `::Object.require 'corelib/irb'` をコメントアウト。
- **検証**: `npm run build` OK / `npm test` 16/16 OK / `wrangler deploy --dry-run` OK。
- **効果**: bundle から `corelib/irb` サブツリー消失（`Opal.modules` 件数減）。

## 2) `opal-parser` 依存の除去

- **変更**:
  - `vendor/sinatra_upstream/base.rb` の `set`: Symbol/Integer/true/false/nil の getter を `inspect` 文字列ではなく **Proc キャプチャ**に変更。
  - 同 `set`: `option?` メソッドを `class_eval("!!…")` ではなく **Proc predicate** で定義。
  - `lib/opal_patches.rb`: `require 'opal-parser'` を削除しコメントで経緯を記載。
- **検証**: build / npm test / 連続 deploy 3 回（B3）成功。
- **効果**: `Opal.modules["opal/compiler"]` および `parser/*` が bundle から **完全消失**。行数・raw・gzip が ~31–34% 減。

## 3) `Sinatra::ShowExceptions` の軽量化（`vendor/sinatra/show_exceptions.rb`）

- **変更**: upstream `sinatra_upstream/show_exceptions`（`rack/show_exceptions` 依存）を読まず、pass-through クラスのみ定義。
- **検証**: build / npm test / deploy 連続成功。
- **効果**: `sinatra_upstream/show_exceptions` モジュールが bundle から消失。

## 4) ローカル D1 schema（`bin/schema.sql`）

- **変更**: `posts` テーブル追加（`db/migrations/0001_create_posts.sql` と整合）。`npm run d1:init` 後の `wrangler dev` で `/posts` smoke を成立。
- **備考**: 本番 D1 は別途 migrations 適用済み前提。ローカル専用 schema の欠落修正。
