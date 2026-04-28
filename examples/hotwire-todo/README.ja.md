# hotwire-todo

> 🇬🇧 English version: [README.md](README.md)

> クライアント側 JavaScript は Stimulus の autofocus controller ひとつだけ。
> それ以外の更新はすべて、`Accept: text/vnd.turbo-stream.html` のネゴシエーションを介して
> サーバー側でレンダリングされる **Turbo Streams** を通って流れる Sinatra アプリ。

## このサンプルが示すもの

- 通常の ERB partial から生成されるサーバーレンダリングの Turbo Stream レスポンス
  (`<turbo-stream action="append" target="...">`) を、**標準** の Sinatra
  呼び出しである `erb :_partial, locals: { t: t }` で組み立てる例。位置引数版
  `erb` のワークアラウンドは不要。
- `db.execute_insert` が `meta['last_row_id']` をトップレベルで返す
  (homura-runtime 0.2.18) ため、挿入したばかりの行が turbo-stream
  内で実際の `N` を持った `<li id="todo-N">` として現れる。
- アクションごとに 2 つの形を返すルート: リクエストが
  `text/vnd.turbo-stream.html` を要求していれば turbo-stream チャンクを返し、
  そうでなければ `redirect '/'` する。
- importmap 経由で読み込まれる Stimulus + Turbo と、`public/assets/hotwire-app.js`
  に置かれた小さなユーザー JS ファイル 1 つ。

## ルート

| Method | Path | Turbo-stream レスポンス | プレーンレスポンス |
|---|---|---|---|
| `GET`  | `/` | — | `<ul id="todos-list">` と新規 todo フォームを含む完全な HTML ページ。 |
| `POST` | `/todos` | `#todos-list` への `append` と `#todo-form` の `replace`。 | `redirect '/'`。 |
| `POST` | `/todos/:id/toggle` | `#todo-N` の `replace`。 | `redirect '/'`。 |
| `POST` | `/todos/:id/delete` | `#todo-N` の `remove`。 | `redirect '/'`。 |

## レイアウト

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

## コードのポイント

### サーバー側でのストリーム生成

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

`erb :_stream_create, layout: false, locals: { t: t }` は **標準** の Sinatra
呼び出しそのもの。partial の中では `t` を直接参照できる。`homura-runtime`
0.2.18 が、レンダラーの locals スタックと小さな `Sinatra::Base#method_missing`
シムを通じて `locals[:t]` を裸の識別子として表に出してくれるので、
`locals[:t]['id']` のように書く必要はない。

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

### クライアント (`public/assets/hotwire-app.js`)

```js
import * as Turbo from '@hotwired/turbo'
import { Application, Controller } from '@hotwired/stimulus'

const app = Application.start()

class FocusController extends Controller {
  connect() { this.element.focus() }
}
app.register('focus', FocusController)
```

クライアント側のコードはこれですべて。

## 実行

```bash
cd examples/hotwire-todo
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://hotwire-todo.localhost:1355/
```

curl からストリームレスポンスを確認する:

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

Turbo の Accept ヘッダーが付いていなければ、同じ POST は `303 See Other`
を返し、ブラウザはそのまま `/` に追従する。つまり JavaScript を無効に
していてもフォームは動く。

## デプロイ

```bash
npx wrangler d1 create hotwire-todo
# 発行された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
