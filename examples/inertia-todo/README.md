# inertia-todo

> A thin SPA via [**Inertia.js**](https://inertiajs.com) + **Vue 3**,
> with **Sinatra** serving page-object props out of D1. The server is
> all Ruby; the client JS is one small file in `public/assets/`.

## What this shows

- The Inertia.js wire protocol implemented from the server side in
  ~30 lines of Sinatra:
  - First request: full HTML page with
    `<div id="app" data-page="<%= Rack::Utils.escape_html(@page_json) %>">`.
  - Subsequent navigation: `X-Inertia: true` requests get the page
    object as JSON, with `Vary: X-Inertia`.
  - `redirect to('/'), 303` for POSTs — Inertia client follows.
  - Asset versioning via a top-level `ASSETS_VERSION` constant and
    `409 Conflict` + `X-Inertia-Location` when versions diverge.
- The Sinatra-standard way of setting Inertia headers — `content_type`
  and `headers`, not a `halt [status, headers, body]` Rack triple.
  This relies on `sinatra-homura` 0.2.17 capturing the final response
  triple after the awaited route body finishes.
- Sinatra-side **D1** access for the actual todo CRUD.
- Client-side **Vue 3 + @inertiajs/vue3** loaded via an importmap and
  a single `public/assets/inertia-app.js`. No bundler step.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/` | Either render the full page (with `data-page`) or, on `X-Inertia: true`, return the JSON page object. |
| `POST` | `/todos` | Insert into D1, `redirect to('/'), 303`. |
| `POST` | `/todos/:id/toggle` | Flip `done`, `redirect to('/'), 303`. |
| `POST` | `/todos/:id/delete` | Delete row, `redirect to('/'), 303`. |

## Layout

```
inertia-todo/
├── Gemfile
├── Rakefile
├── wrangler.toml                     # D1 binding "DB" → database "inertia-todo"
├── app/app.rb                        # render_inertia + CRUD routes
├── views/layout.erb                  # importmap + #app[data-page]
├── public/
│   ├── assets/inertia-app.js         # Vue 3 + Inertia bootstrap
│   └── robots.txt
└── db/migrate/
    ├── 001_create_todos.rb
    └── 001_create_todos.sql
```

## How the server speaks Inertia

```ruby
ASSETS_VERSION = '2'

helpers do
  def render_inertia(component, props)
    page = { component: component, props: props,
             url: request.fullpath, version: ASSETS_VERSION }
    json = page.to_json

    if inertia_request?
      content_type 'application/json'
      headers 'X-Inertia' => 'true', 'Vary' => 'X-Inertia'
      return json
    end

    @page_json = json
    erb :layout, layout: false
  end

  def inertia_request?
    request.env['HTTP_X_INERTIA'] == 'true'
  end
end

before do
  if inertia_request? && request.env['HTTP_X_INERTIA_VERSION'] != ASSETS_VERSION
    halt 409, { 'X-Inertia-Location' => request.fullpath }, ''
  end
end

get '/' do
  rows = db.execute('SELECT id, title, done FROM todos ORDER BY id')
            .map { |r| { 'id' => r['id'], 'title' => r['title'], 'done' => r['done'].to_i == 1 } }
  render_inertia('Todos', { todos: rows })
end
```

## Layout (HTML side)

```erb
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Inertia × homura Todo</title>
  <script type="importmap">
  { "imports": {
      "vue":              "https://esm.sh/vue@3.5.13/dist/vue.esm-browser.prod.js",
      "@inertiajs/vue3":  "https://esm.sh/@inertiajs/vue3@1.3.0?deps=vue@3.5.13"
  }}
  </script>
  <script type="module" src="/assets/inertia-app.js"></script>
</head>
<body>
  <div id="app" data-page="<%= Rack::Utils.escape_html(@page_json) %>"></div>
</body>
</html>
```

`Rack::Utils.escape_html(@page_json)` is the only "trick" here — JSON
naturally contains `"`, which would break the HTML attribute without
escaping.

## Client bootstrap (`public/assets/inertia-app.js`)

```js
import { createApp, h } from 'vue'
import { createInertiaApp } from '@inertiajs/vue3'

const Todos = {
  props: ['todos'],
  template: `<div class="page"> ... </div>`,
  data() { return { title: '' } },
  methods: {
    submit() { this.$inertia.post('/todos', { title: this.title }, { onSuccess: () => this.title = '' }) },
    toggle(id) { this.$inertia.post(`/todos/${id}/toggle`) },
    del(id)    { this.$inertia.post(`/todos/${id}/delete`) }
  }
}

createInertiaApp({
  resolve: name => Promise.resolve({ Todos }[name]),  // Inertia v1 wants a Promise
  setup({ el, App, props, plugin }) {
    createApp({ render: () => h(App, props) }).use(plugin).mount(el)
  }
})
```

## Run it

```bash
cd examples/inertia-todo
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://inertia-todo.localhost:1355/
```

Test that the JSON path returns the right headers:

```bash
curl -sS -i -H 'X-Inertia: true' -H 'X-Inertia-Version: 2' \
        http://inertia-todo.localhost:1355/

# HTTP/1.1 200 OK
# content-type: application/json
# x-inertia: true
# vary: X-Inertia
#
# {"component":"Todos","props":{"todos":[...]},"url":"/","version":"2"}
```

Then open the URL in a browser — adding, toggling, and deleting a todo
all go through Inertia POSTs and update the page without a full reload.

## Deploy

```bash
npx wrangler d1 create inertia-todo
# paste the new database_id into wrangler.toml
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
