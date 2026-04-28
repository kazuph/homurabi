# todo

> The smallest **D1-backed CRUD** in the homura family — no ORM, just
> `env['cloudflare.DB']` and the `Cloudflare::D1Database` API.

## What this shows

- A `Sinatra::Base` subclass built with the published homura gems only
  (no `path:` references).
- Reading and writing **Cloudflare D1** with the sqlite3-ruby-shaped
  wrapper that ships in `homura-runtime` (`db.execute`,
  `db.execute_insert`).
- Sequel migrations compiled to wrangler-ready SQL via
  `homura db:migrate:compile` — but no Sequel at runtime.
- Standard Sinatra `redirect '/'`, no `[303, ...]` Rack-tuple workarounds.
- A two-template ERB setup (`views/layout.erb` + `views/index.erb`)
  precompiled at build time.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/` | List all todos and render the new-todo form. |
| `POST` | `/todos` | Insert `params[:title]` into D1, then `redirect '/'`. |
| `POST` | `/todos/:id/toggle` | Flip the `done` column on the row. |
| `POST` | `/todos/:id/delete` | Delete the row. |

## Layout

```
todo/
├── Gemfile             # opal-homura / homura-runtime / sinatra-homura / sequel-d1*
├── Rakefile            # build / dev / deploy / db:migrate:{compile,local,remote}
├── config.ru           # require_relative 'app/app'; run App
├── wrangler.toml       # D1 binding "DB" → database "todo"
├── app/app.rb          # the Sinatra app
├── views/
│   ├── layout.erb
│   └── index.erb
├── db/migrate/
│   ├── 001_create_todos.rb     # Sequel migration DSL
│   └── 001_create_todos.sql    # compiled by `homura db:migrate:compile`
└── public/robots.txt
```

`sequel-d1` is in the Gemfile only to drive the migration compile under
CRuby; the runtime app does not `require 'sequel'`.

## How D1 access looks

```ruby
class App < Sinatra::Base
  helpers do
    def db
      env['cloudflare.DB']
    end
  end

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

D1 row hashes have **string keys** (`t['title']`, not `t[:title]`), and
`done` is an integer (`0` / `1`) — those two facts are the only places
the `views/index.erb` differs from a CRuby SQLite version.

## Run it

```bash
cd examples/todo
bundle install
npm install

# Apply the migration to the local D1 sqlite shim.
bundle exec rake db:migrate:local

# Build the Worker bundle.
bundle exec rake build

# Start wrangler dev (through portless if installed).
bundle exec rake dev
# → http://todo.localhost:1355/  (portless)
# or http://127.0.0.1:8787/      (plain wrangler dev fallback)
```

Test with curl:

```bash
curl -sS -i http://todo.localhost:1355/
curl -sS -i -X POST http://todo.localhost:1355/todos -d 'title=Buy milk'
curl -sS -i -X POST http://todo.localhost:1355/todos/1/toggle
curl -sS -i -X POST http://todo.localhost:1355/todos/1/delete
```

## Deploy

```bash
npx wrangler d1 create todo                  # one-time; copy the database_id
# paste it into wrangler.toml under [[d1_databases]]
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
