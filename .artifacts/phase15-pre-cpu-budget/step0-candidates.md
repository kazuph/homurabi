# Step 0 — 削減候補（実測 `Opal.modules` ＋ grep 根拠）

## 除外（触らない）

- **stringio**: PLAN 指示 — cloudflare_workers / rack mock / multipart 経路で使用のため候補外。
- **Mustermann composite/concat/identity/AST/sinatra/regular**: PLAN 指示 — 保護対象。

## 候補 A: `corelib/irb`（`vendor/opal-gem/opal/opal.rb`）

- **実在**: 初期 baseline bundle に `Opal.modules["corelib/irb"]` が存在。
- **未使用根拠**: `app/`・`lib/`（`opal_patches` 除く）に `binding.irb` / `IRB` 呼び出しなし。Workers 本番で REPL 不要。

## 候補 B: ランタイム `opal-parser`（`lib/opal_patches.rb`）

- **実在**: baseline に `opal/compiler`・`parser/*` が大量に存在。
- **根拠**: `lib/opal_patches.rb` が `require 'opal-parser'` でコンパイラ木を引き込んでいた。
- **置換方針**: Sinatra upstream `set` が `value.inspect` 経由で `class_eval("def …")` するのをやめ、Proc ベースの getter / predicate に変更し、`require 'opal-parser'` を削除（Step 1 で実施）。

## 候補 C: `sinatra/show_exceptions` → upstream 経路の排除

- **実在**: baseline に `sinatra_upstream/show_exceptions` / `rack/show_exceptions`（巨大テンプレート含む経路）。
- **方針**: `vendor/sinatra/show_exceptions.rb` を pass-through の軽量 `Sinatra::ShowExceptions` に差し替え、`sinatra_upstream/show_exceptions` をロードしない（Step 1）。

## 候補 D: Mustermann 追加 dialect（template/rails/shell 等）

- **調査結果**: vendored `vendor/mustermann/` に該当 dialect ファイルは同梱されておらず、`build/hello.no-exit.mjs` にも `mustermann/template` 等は **出現しない**。Step 2 は **該当なし（N/A）** と記録。
