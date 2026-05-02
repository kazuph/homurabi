> 🇬🇧 English version: [README.md](README.md)

# todo

> homura ファミリー最小の **ORM なしの D1 CRUD** —
> `db` と `Cloudflare::D1Database` API だけで構成する。

## このサンプルが示すもの

- 公開済みの homura gem のみで組み立てた `Sinatra::Base` のサブクラス
  （`path:` 参照は使わない）。
- `homura-runtime` に同梱される sqlite3-ruby 風のラッパー
  （`db.execute`, `db.execute_insert`）を使った **Cloudflare D1** への
  読み書き。
- `homura db:migrate:compile` 経由で wrangler 向け SQL にコンパイル
  される Sequel マイグレーション — ただしランタイムでは Sequel を
  使わない。
- 標準の Sinatra `redirect '/'`。`[303, ...]` のような Rack タプル
  ワークアラウンドは不要。
- ビルド時にプリコンパイルされる ERB テンプレート 2 枚構成
  （`views/layout.erb` + `views/index.erb`）。

## ルーティング

| Method | Path | 動作 |
|---|---|---|
| `GET`  | `/` | todo を一覧表示し、新規作成フォームを描画する。 |
| `POST` | `/todos` | `params[:title]` を D1 に INSERT し、`redirect '/'`。 |
| `POST` | `/todos/:id/toggle` | 該当行の `done` カラムを反転させる。 |
| `POST` | `/todos/:id/delete` | 該当行を削除する。 |

## ディレクトリ構成

```
todo/
├── Gemfile             # opal-homura / homura-runtime / sinatra-homura / sequel-d1*
├── Rakefile            # build / dev / deploy / db:migrate:{compile,local,remote}
├── config.ru           # require_relative 'app/app'; run App
├── wrangler.toml       # D1 バインディング "DB" → データベース "todo"
├── app/app.rb          # Sinatra アプリ本体
├── views/
│   ├── layout.erb
│   └── index.erb
├── db/migrate/
│   ├── 001_create_todos.rb     # Sequel マイグレーション DSL
│   └── 001_create_todos.sql    # `homura db:migrate:compile` でコンパイル
└── public/robots.txt
```

`sequel-d1` は CRuby 上でマイグレーションをコンパイルさせるためだけに
Gemfile に入っており、ランタイムのアプリは `require 'sequel'` しない。

## D1 アクセスの書き方

```ruby
class App < Sinatra::Base
  get '/' do
    @todos = db.execute('SELECT id, title, done, created_at FROM todos ORDER BY id')
    erb :index
  end

  post '/todos' do
    db.execute_insert(
      'INSERT INTO todos (title, done, created_at) VALUES (?, ?, ?)',
      [params[:title].to_s.strip, 0, Time.now.to_i]
    )
    redirect '/'
  end
end
```

D1 の行ハッシュは **文字列キー** を持ち（`t['title']` であって
`t[:title]` ではない）、`done` は整数（`0` / `1`）になる。
`views/index.erb` が CRuby SQLite 版と異なるのは、この 2 点だけだ。

## 起動

```bash
cd examples/todo
bundle install
npm install

# ローカル D1 sqlite shim にマイグレーションを適用する。
bundle exec rake db:migrate:local

# Worker バンドルをビルドする。
bundle exec rake build

# wrangler dev を起動（portless がインストールされていればそれ経由）。
bundle exec rake dev
# → http://todo.localhost:1355/  (portless)
# または http://127.0.0.1:8787/  (素の wrangler dev フォールバック)
```

curl での動作確認:

```bash
curl -sS -i http://todo.localhost:1355/
curl -sS -i -X POST http://todo.localhost:1355/todos -d 'title=Buy milk'
curl -sS -i -X POST http://todo.localhost:1355/todos/1/toggle
curl -sS -i -X POST http://todo.localhost:1355/todos/1/delete
```

## デプロイ

```bash
npx wrangler d1 create todo                  # 初回のみ。出力された database_id をコピーする
# wrangler.toml の [[d1_databases]] に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
