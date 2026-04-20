# Step 3 — Sinatra extension / eager load

## 実施内容

- **ShowExceptions**: `vendor/sinatra/show_exceptions.rb` を upstream 委譲から **軽量 pass-through** に変更。`disable :logging` 等の設定だけでは bundle が減らない問題に対し、**物理的に** `sinatra_upstream/show_exceptions` とその巨大 HTML 経路をバンドルから外した。
- **opal-parser 除去**（Step 1 と併記）: Sinatra `set` の文字列 `class_eval` 依存を解消し、起動時にコンパイラ木を引き込まないようにした。

## 未実施（保留）

- `Sinatra::CommonLogger` / `middleware/logger` の require 切断は、今回の B3（deploy 3 連）達成後の追加チューニングとして **スコープ外**（リスク対効果のトレードオフ）。
