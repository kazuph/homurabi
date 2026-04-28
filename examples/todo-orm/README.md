# todo-orm

> The same TODO domain as [`todo/`](../todo/), but written through
> [`sequel-d1`](https://rubygems.org/gems/sequel-d1) — datasets, lazy
> chains, raw `Sequel.lit` value writes, and migrations in Sequel DSL.

## What this shows

- `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` — exactly
  how the docs spell it.
- Sequel **dataset** API: `db[:todos].order(:id).all`,
  `db[:todos].where(id: 1).first`,
  `db[:todos].where(id: 1).update(done: Sequel.lit('1 - done'))`,
  `db[:todos].where(id: 1).delete`.
- A Sequel migration in `db/migrate/001_create_todos.rb` that compiles
  to wrangler-ready SQL via `homura db:migrate:compile` and applies
  with `wrangler d1 migrations apply`.
- Standard Sinatra `redirect '/'` everywhere — no Rack-tuple shortcuts,
  no Sequel-fragment workarounds.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/` | `db[:todos].order(:id).all` → ERB list. |
| `POST` | `/todos` | `db[:todos].insert(...)` → `redirect '/'`. |
| `POST` | `/todos/:id/toggle` | `db[:todos].where(id:).update(done: Sequel.lit('1 - done'))`. |
| `POST` | `/todos/:id/delete` | `db[:todos].where(id:).delete`. |

`update(done: Sequel.lit('1 - done'))` is the natural Sequel idiom for
"flip a boolean integer column in place." It works because
`sequel-d1` 0.2.10 routes `Sequel::LiteralString` through
`literal_literal_string_append` instead of the Symbol branch (a real
Opal-specific quirk: under Opal `Sequel::LiteralString.is_a?(Symbol)`
is `true` because Symbol == String).

## Layout

```
todo-orm/
├── Gemfile                       # adds sequel-d1, sequel, sqlite3
├── Rakefile                      # + db:migrate:{compile,local,remote}
├── wrangler.toml                 # D1 binding "DB" → database "todo-orm"
├── app/app.rb                    # the Sinatra app + Sequel routes
├── views/{layout,index}.erb
├── db/migrate/
│   ├── 001_create_todos.rb       # Sequel migration DSL
│   └── 001_create_todos.sql      # compiled at `db:migrate:compile`
└── public/robots.txt
```

## How a route looks

```ruby
class App < Sinatra::Base
  helpers do
    def db
      Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
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

`Dataset#all` and `Dataset#update` resolve asynchronously inside the
Workers runtime; the build pipeline's auto-await pass inserts the
required `__await__` calls so application code stays sync-shaped.

## Run it

```bash
cd examples/todo-orm
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://todo-orm.localhost:1355/
```

Test with curl:

```bash
curl -sS -i -X POST http://todo-orm.localhost:1355/todos -d 'title=Pay rent'
curl -sS -i -X POST http://todo-orm.localhost:1355/todos/1/toggle
curl -sS    http://todo-orm.localhost:1355/                # done=true
curl -sS -i -X POST http://todo-orm.localhost:1355/todos/1/delete
```

## Deploy

```bash
npx wrangler d1 create todo-orm
# paste the new database_id into wrangler.toml
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
