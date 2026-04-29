> 🇯🇵 日本語版: [README.ja.md](README.ja.md)

# todo-simple

> The smallest possible homura example. **One Ruby file**, no
> `Sinatra::Base` subclass, no `views/` directory, no D1, no
> migrations — classic-style top-level DSL with HTML written as Ruby
> heredocs right next to the routes.

## What this shows

This is the example to copy when you want to demonstrate
"how little homura needs". Compared to [`todo/`](../todo/) it removes:

| | `todo/` | `todo-simple/` |
|---|---|---|
| Code shape | `class App < Sinatra::Base` (modular) | classic top-level DSL |
| Code split | `app/app.rb` + `views/*.erb` | one `app.rb` at the project root |
| Persistence | Cloudflare D1 | a Ruby array (in-memory) |
| Migrations | yes | none |
| Templates | precompiled ERB | inline Ruby heredocs |
| `wrangler.toml` bindings | `[[d1_databases]]` | none |
| Files in repo | ~10 | 6 |

It is otherwise the same Sinatra you'd write on Puma:

```ruby
require 'sinatra'

TODOS = []
NEXT_ID = [1]

get '/' do
  page <<~HTML
    <h1>todo-simple</h1>
    ...
    #{todos_html}
  HTML
end

post '/todos' do
  TODOS << { id: NEXT_ID[0], title: params[:title], done: false }
  NEXT_ID[0] += 1
  redirect '/'
end
# ...

run Sinatra::Application
```

Routes are registered straight on the top-level Sinatra `main`
delegator — exactly the shape you'd see on a vanilla Sinatra README.
Data lives in a top-level `TODOS` array, which means **the Worker
isolate's lifetime is the data's lifetime**. Restart `wrangler dev`
and your todos are gone. This is the price you pay for "no setup".

## Layout

```
todo-simple/
├── Gemfile           # opal-homura, homura-runtime, sinatra-homura — that's it
├── Rakefile          # build / dev / deploy
├── config.ru         # require_relative 'app'
├── wrangler.toml     # main = "build/worker.entrypoint.mjs", no bindings
├── package.json      # devDep: wrangler
├── app.rb            # ← everything happens here
└── public/robots.txt
```

No `app/` subdirectory, no `views/` subdirectory, no `db/` subdirectory.

## Run it

```bash
cd examples/todo-simple
bundle install
npm install

bundle exec rake build
bundle exec rake dev
# → http://todo-simple.localhost:1355/
```

Try it with curl:

```bash
curl -sS -i http://todo-simple.localhost:1355/
curl -sS -i -X POST http://todo-simple.localhost:1355/todos -d 'title=Buy milk'
curl -sS    http://todo-simple.localhost:1355/
curl -sS -i -X POST http://todo-simple.localhost:1355/todos/1/toggle
curl -sS -i -X POST http://todo-simple.localhost:1355/todos/1/delete
```

## Deploy

```bash
bundle exec rake deploy
```

No D1 setup, no secrets — `wrangler deploy` and you're done.

## When NOT to use this layout

The moment you want any of the following, copy
[`todo/`](../todo/) or [`todo-orm/`](../todo-orm/) instead:

- Data that survives a Worker restart → use **D1**.
- HTML longer than ~30 lines → use **`views/*.erb`** so changing
  markup doesn't mean editing Ruby strings.
- More than a couple of routes per file → split into `app/app.rb`
  plus a `routes/` directory.

`todo-simple` exists to show that homura doesn't *force* any of those
on you for tiny apps.
