# Step 2 — Mustermann dialect

## 調査

- `vendor/sinatra_upstream/base.rb` は `require 'mustermann'` / `mustermann/sinatra` / `mustermann/regular` のみ。
- `build/hello.no-exit.mjs` を grep しても `mustermann/template` / `rails` / `shell` / `pyramid` / `flask` 系の `Opal.modules` は **存在しない**（vendored tree にも該当ファイルなし）。

## 結論

- **削減対象なし（N/A）**。既存 bundle は Sinatra 4.x + homurabi vendor 構成において追加 dialect が同梱されていない。
