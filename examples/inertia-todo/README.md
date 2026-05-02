# inertia-todo

> A thin SPA via [**Inertia.js**](https://inertiajs.com) + **React**,
> with **Sinatra** serving page props from D1. The server is Ruby, the
> client is a small Vite bundle, and the deployed Worker uses released gems
> only.

## What this shows

- `sinatra-inertia` handling the Inertia v2 protocol while route code stays
  Sinatra-shaped.
- Sinatra-side **D1** access for todo CRUD through `sequel-d1`.
- Shared props, redirect validation errors, CSRF, deferred props, and partial
  reloads without hand-writing protocol headers in the app.

## Server shape

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

The app still requires and registers `Sinatra::Inertia`, but route code uses
page-level nouns: `render`, `share_props`, `defer`, and `page_errors`.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET` | `/` | Render the full HTML page, or return a JSON page object on `X-Inertia: true`. |
| `POST` | `/todos` | Insert a todo into D1 and redirect back. |
| `POST` | `/todos/:id/toggle` | Toggle `done` and redirect back. |
| `POST` | `/todos/:id/delete` | Delete the row and redirect back. |

## Layout

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

## Run it

```bash
cd examples/inertia-todo
bundle install
npm install

bundle exec rake db:migrate:local
npm run build
npm run dev
```

Then open `http://inertia-todo.localhost:1355/`.

## Deploy

```bash
bundle exec rake db:migrate:remote
npm run deploy
```
