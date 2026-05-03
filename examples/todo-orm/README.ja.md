> 🇬🇧 English version: [README.md](README.md)

# todo-orm

> [`todo/`](../todo/) と同じ TODO ドメインを、
> [`sequel-d1`](https://rubygems.org/gems/sequel-d1) 経由で書き直したサンプル。
> データセット、遅延チェイン、`Sequel.lit` による生の値書き込み、Sequel DSL
> でのマイグレーションを扱う。

## このサンプルで示すこと

- `Sequel.connect(adapter: :d1, d1: d1)` —
  ドキュメントに書かれているそのままの書き方。
- Sequel の **dataset** API: `db[:todos].order(:id).all`、
  `db[:todos].where(id: 1).first`、
  `db[:todos].where(id: 1).update(done: Sequel.lit('1 - done'))`、
  `db[:todos].where(id: 1).delete`。
- `db/migrate/001_create_todos.rb` の Sequel マイグレーションは、
  `homura db:migrate:compile` で wrangler 対応の SQL にコンパイルされ、
  `wrangler d1 migrations apply` で適用できる。
- どこでも標準の Sinatra `redirect '/'` を使う。Rack タプルのショートカットも、
  Sequel フラグメントの回避策も使わない。

## ルート

| Method | Path | 動作 |
|---|---|---|
| `GET`  | `/` | `db[:todos].order(:id).all` の結果を ERB のリストで表示。 |
| `POST` | `/todos` | `db[:todos].insert(...)` 後に `redirect '/'`。 |
| `POST` | `/todos/:id/toggle` | `db[:todos].where(id:).update(done: Sequel.lit('1 - done'))`。 |
| `POST` | `/todos/:id/delete` | `db[:todos].where(id:).delete`。 |

`update(done: Sequel.lit('1 - done'))` は「整数で表すブーリアンカラムを
その場で反転する」ための Sequel らしい自然なイディオムである。
これが動くのは、`sequel-d1` 0.2.10 が `Sequel::LiteralString` を
Symbol 分岐ではなく `literal_literal_string_append` 経由で処理して
いるためである（Opal 特有のクセで、Opal 環境では Symbol == String の
ため `Sequel::LiteralString.is_a?(Symbol)` が `true` になる）。

## ディレクトリ構成

```
todo-orm/
├── Gemfile                       # sequel-d1, sequel, sqlite3 を追加
├── Rakefile                      # + db:migrate:{compile,local,remote}
├── wrangler.toml                 # D1 binding "DB" → database "todo-orm"
├── app/app.rb                    # Sinatra アプリ + Sequel ルート
├── views/{layout,index}.erb
├── db/migrate/
│   ├── 001_create_todos.rb       # Sequel マイグレーション DSL
│   └── 001_create_todos.sql      # `db:migrate:compile` 時にコンパイルされる
└── public/robots.txt
```

## ルートの書き方

```ruby
class App < Sinatra::Base
  helpers do
    def db
      Sequel.connect(adapter: :d1, d1: d1)
    end
  end

  get '/' do
    @todos = db[:todos].order(:id).all
    erb :index
  end

  post '/todos' do
    db[:todos].insert(title: params[:title], done: 0, created_at: Time.now.to_i)
    redirect '/'
  end

  post '/todos/:id/toggle' do
    db[:todos].where(id: params[:id].to_i).update(done: Sequel.lit('1 - done'))
    redirect '/'
  end
end
```

`Dataset#all` と `Dataset#update` は Workers ランタイム内では非同期 API を通る。
ビルドパイプラインがその境界を処理するので、アプリケーション側のコードは同期的な見た目のまま保てる。

## 実行方法

```bash
cd examples/todo-orm
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://todo-orm.localhost:1355/
```

curl で動作確認する。

```bash
curl -sS -i -X POST http://todo-orm.localhost:1355/todos -d 'title=Pay rent'
curl -sS -i -X POST http://todo-orm.localhost:1355/todos/1/toggle
curl -sS    http://todo-orm.localhost:1355/                # done=true
curl -sS -i -X POST http://todo-orm.localhost:1355/todos/1/delete
```

## デプロイ

```bash
npx wrangler d1 create todo-orm
# 払い出された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
