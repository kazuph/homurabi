# inertia-todo

> English version: [README.md](README.md)

> [**Inertia.js**](https://inertiajs.com) + **React** による薄い SPA。
> **Sinatra** が D1 から page props を返し、Worker にはリリース済み gem
> だけでデプロイする。

## 何を示すサンプルか

- `sinatra-inertia` が Inertia v2 プロトコルを引き受け、ルート実装は
  Sinatra らしい形に保つ。
- todo CRUD は Sinatra 側から **D1** にアクセスして行う。
- shared props、redirect validation errors、CSRF、deferred props、
  partial reloads をアプリ側でヘッダーを手書きせずに使う。

## サーバーの形

```ruby
class App < Sinatra::Base
  register Sinatra::Inertia

  set :page_version, ENV.fetch('ASSETS_VERSION', '3')
  set :page_layout, :layout

  share_props do
    { flash: flash_payload, csrfToken: csrf_token }
  end

  get '/' do
    render 'Todos/Index',
           todos: -> { todos },
           stats: defer(group: 'meta') { todo_stats }
  end

  post '/todos' do
    if title.empty?
      page_errors title: 'title is required'
      redirect to('/'), 303
    end

    db[:todos].insert(title: title, done: 0, created_at: Time.now.to_i)
    redirect to('/'), 303
  end
end
```

`Sinatra::Inertia` の require/register は残るが、ルートコードでは
`render`、`share_props`、`defer`、`page_errors` という page レベルの
語彙で書ける。

## ルート

| Method | Path | 動作 |
|---|---|---|
| `GET` | `/` | フル HTML、または `X-Inertia: true` なら JSON page object を返す。 |
| `POST` | `/todos` | D1 に todo を追加してリダイレクトする。 |
| `POST` | `/todos/:id/toggle` | `done` を反転してリダイレクトする。 |
| `POST` | `/todos/:id/delete` | 行を削除してリダイレクトする。 |

## レイアウト

```
inertia-todo/
├── Gemfile
├── Rakefile
├── wrangler.toml
├── app/app.rb
├── views/layout.erb
├── client/src/main.tsx
├── client/src/Pages/Todos/Index.tsx
├── public/
│   └── robots.txt
└── db/migrate/
    ├── 001_create_todos.rb
    └── 001_create_todos.sql
```

## 動かし方

```bash
cd examples/inertia-todo
bundle install
npm install

bundle exec rake db:migrate:local
npm run build
npm run dev
```

その後 `http://inertia-todo.localhost:1355/` を開く。

## デプロイ

```bash
bundle exec rake db:migrate:remote
npm run deploy
```
