# todo (homura example)

公開gemのみで動く、Cloudflare Workers 上の Sinatra による in-memory TODO アプリです。

## 構成

- `app/app.rb` — Sinatraアプリ本体（`@@todos` クラス変数で保持）
- `views/layout.erb` — レイアウト + inline CSS
- `views/index.erb` — 一覧 + 追加/トグル/削除フォーム
- `config.ru` — `run App`
- `Gemfile` — `opal-homura` / `homura-runtime` / `sinatra-homura` の公開gemのみ

## ルート

| Method | Path | 説明 |
| --- | --- | --- |
| GET  | `/` | 一覧表示 + 追加フォーム |
| POST | `/todos` | `title` を新規追加 |
| POST | `/todos/:id/toggle` | done フラグの反転 |
| POST | `/todos/:id/delete` | 削除 |

## 使い方

```bash
bundle install
bundle exec rake build
npx wrangler dev --local --port 8787 --ip 127.0.0.1
```

## 注意

データは Worker isolate のメモリ上にしか存在しません。デプロイ、isolateの再起動、
リクエストが別 isolate に振り分けられた場合などで簡単に消えます。永続化したい場合は
`--with-db` で生成される D1 例や、KV を使う構成を参照してください。
