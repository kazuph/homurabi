# inertia-todo

> 🇬🇧 English version: [README.md](README.md)

> [**Inertia.js**](https://inertiajs.com) + **Vue 3** による薄い SPA で、
> **Sinatra** が D1 から page object の props を返す構成。サーバーは
> すべて Ruby、クライアント JS は `public/assets/` の小さなファイル 1 本だけ。

## 何を示すサンプルか

- Inertia.js のワイヤープロトコルを Sinatra 側 30 行程度で実装している:
  - 初回リクエスト: `<div id="app" data-page="<%= Rack::Utils.escape_html(@page_json) %>">`
    を含むフル HTML ページを返す。
  - 以降のナビゲーション: `X-Inertia: true` リクエストには page object を
    JSON で返し、`Vary: X-Inertia` を付与する。
  - POST には `redirect to('/'), 303` を返す（Inertia クライアントが追従する）。
  - アセットのバージョニングはトップレベル定数 `ASSETS_VERSION` で行い、
    バージョンが食い違う場合は `409 Conflict` + `X-Inertia-Location` を返す。
- Inertia ヘッダーの設定は Sinatra の標準的な書き方—`content_type` と
  `headers` を使い、`halt [status, headers, body]` の Rack トリプルは
  使わない。これは `sinatra-homura` 0.2.17 が、await されたルート本体の
  完了後に最終レスポンストリプルをキャプチャしてくれることに依存している。
- 実際の todo CRUD は Sinatra 側からの **D1** アクセスで行う。
- クライアント側は **Vue 3 + @inertiajs/vue3** を importmap で読み込み、
  単一の `public/assets/inertia-app.js` で起動する。バンドラのステップは無い。

## ルート

| Method | Path | 動作 |
|---|---|---|
| `GET`  | `/` | フルページ（`data-page` 付き）をレンダリング、もしくは `X-Inertia: true` の場合は JSON の page object を返す。 |
| `POST` | `/todos` | D1 に INSERT し、`redirect to('/'), 303`。 |
| `POST` | `/todos/:id/toggle` | `done` を反転し、`redirect to('/'), 303`。 |
| `POST` | `/todos/:id/delete` | 行を削除し、`redirect to('/'), 303`。 |

## レイアウト

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
├── db/migrate/
│   ├── 001_create_todos.rb
│   └── 001_create_todos.sql
└── cf-runtime/                       # bridging mjs files
```

## サーバーが Inertia を喋る方法

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

## レイアウト（HTML 側）

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

ここでの唯一の「コツ」は `Rack::Utils.escape_html(@page_json)` で、JSON には
当然 `"` が含まれており、エスケープしないと HTML 属性が壊れてしまう。

## クライアント起動 (`public/assets/inertia-app.js`)

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
  resolve: name => Promise.resolve({ Todos }[name]),  // Inertia v1 は Promise を要求する
  setup({ el, App, props, plugin }) {
    createApp({ render: () => h(App, props) }).use(plugin).mount(el)
  }
})
```

## 動かし方

```bash
cd examples/inertia-todo
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://inertia-todo.localhost:1355/
```

JSON パスが正しいヘッダーを返すかを確認する:

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

その後ブラウザで URL を開けば、todo の追加・トグル・削除はすべて Inertia
の POST を経由し、フルリロードなしにページが更新される。

## デプロイ

```bash
npx wrangler d1 create inertia-todo
# 発行された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
