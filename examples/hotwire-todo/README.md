# hotwire-todo

> A Sinatra app whose only client-side JavaScript is one Stimulus
> autofocus controller — every update flows through **Turbo Streams**
> rendered server-side over `Accept: text/vnd.turbo-stream.html`
> negotiation.

## What this shows

- Server-rendered Turbo Stream responses (`<turbo-stream
  action="append" target="...">`) generated from ordinary ERB
  partials with the **standard** Sinatra `erb :_partial, locals: { t: t }`
  call — no positional-`erb` workaround.
- `db.execute_insert` returns `meta['last_row_id']` at the top level
  (homura-runtime 0.2.18), so the freshly-inserted row appears in the
  turbo-stream as `<li id="todo-N">` with a real `N`.
- A two-shape route per action: when the request asks for
  `text/vnd.turbo-stream.html`, return a turbo-stream chunk; otherwise
  `redirect '/'`.
- Stimulus + Turbo loaded over an importmap, with one tiny user JS file
  in `public/assets/hotwire-app.js`.

## Routes

| Method | Path | Turbo-stream response | Plain response |
|---|---|---|---|
| `GET`  | `/` | — | Full HTML page with `<ul id="todos-list">` and the new-todo form. |
| `POST` | `/todos` | `append` to `#todos-list` + `replace` of `#todo-form`. | `redirect '/'`. |
| `POST` | `/todos/:id/toggle` | `replace` `#todo-N`. | `redirect '/'`. |
| `POST` | `/todos/:id/delete` | `remove` `#todo-N`. | `redirect '/'`. |

## Layout

```
hotwire-todo/
├── Gemfile
├── Rakefile
├── wrangler.toml                       # D1 binding "DB" → "hotwire-todo"
├── app/app.rb                          # routes + render_streams helper
├── views/
│   ├── layout.erb                      # importmap + /assets/hotwire-app.js
│   ├── index.erb                       # form + initial <ul>
│   ├── _form.erb                       # the new-todo form (replace target)
│   └── _todo.erb                       # one <li> partial
├── public/
│   ├── assets/hotwire-app.js           # Turbo + Stimulus controller
│   └── robots.txt
├── db/migrate/
│   ├── 001_create_todos.rb
│   └── 001_create_todos.sql
└── cf-runtime/
```

## Code highlights

### Server-side stream generation

```ruby
post '/todos' do
  title = params[:title].to_s.strip
  return redirect '/' if title.empty?

  meta = db.execute_insert(
    'INSERT INTO todos (title, done, created_at) VALUES (?, ?, ?)',
    [title, 0, Time.now.to_i]
  )
  t = { 'id' => meta['last_row_id'], 'title' => title, 'done' => 0 }

  if turbo_stream_request?
    content_type 'text/vnd.turbo-stream.html'
    erb :_stream_create, layout: false, locals: { t: t }
  else
    redirect '/'
  end
end
```

`erb :_stream_create, layout: false, locals: { t: t }` is the
**standard** Sinatra call. Inside the partial, you reference `t`
directly — `homura-runtime` 0.2.18 surfaces `locals[:t]` as a bare
identifier through the renderer's locals stack and a small
`Sinatra::Base#method_missing` shim, so you don't have to write
`locals[:t]['id']`.

### `views/_todo.erb`

```erb
<li id="todo-<%= t['id'] %>">
  <span style="<%= 'text-decoration:line-through' if t['done'].to_i == 1 %>">
    <%= h(t['title']) %>
  </span>
  <form action="/todos/<%= t['id'] %>/toggle" method="post" data-turbo-stream>
    <button><%= t['done'].to_i == 1 ? '↩' : '✓' %></button>
  </form>
  <form action="/todos/<%= t['id'] %>/delete" method="post" data-turbo-stream>
    <button>削除</button>
  </form>
</li>
```

### Client (`public/assets/hotwire-app.js`)

```js
import * as Turbo from '@hotwired/turbo'
import { Application, Controller } from '@hotwired/stimulus'

const app = Application.start()

class FocusController extends Controller {
  connect() { this.element.focus() }
}
app.register('focus', FocusController)
```

That is the complete client surface.

## Run it

```bash
cd examples/hotwire-todo
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://hotwire-todo.localhost:1355/
```

Verify the stream response from curl:

```bash
curl -sS -i \
     -H 'Accept: text/vnd.turbo-stream.html, text/html' \
     -X POST http://hotwire-todo.localhost:1355/todos \
     -d 'title=Pay rent'

# HTTP/1.1 200 OK
# content-type: text/vnd.turbo-stream.html;charset=utf-8
#
# <turbo-stream action="append" target="todos-list">
#   <template><li id="todo-1"> ... </li></template>
# </turbo-stream>
```

Without the Turbo Accept header, the same POST returns `303 See Other`
and the browser follows it to `/` — so the form works even with
JavaScript disabled.

## Deploy

```bash
npx wrangler d1 create hotwire-todo
# paste the new database_id into wrangler.toml
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
