> 🇬🇧 English version: [README.md](README.md)

# blog

> 小さな **D1 バックエンドのブログ** — 一覧、詳細、新規投稿フォーム、**ちゃんとした
> 404**、そして削除を備える。404 ルートはこのデモの肝で、
> `sinatra-homura` 0.2.17 における async ルートのステータス保持を
> 実地で検証する役割を持つ。

## このサンプルで示すこと

- Sequel を介さず、Cloudflare D1 に対する Sinatra の読み書きインターフェイスを
  ひととおり使う — `db.execute`、`db.execute_insert`、`db.get_first_row`。
- `status 404; erb :posts_not_found` が実際に **404** を返す（200 ではない）。
  以前の sinatra-homura では、await された継続が完了する前に
  `response.status` をスナップショットしてしまい、最終的に上書きされていた。
  0.2.17 では、すべての Promise が解決された後に最終的な triple をキャプチャするようになった。
- 通常の Sinatra レイアウトとサブテンプレート構成: `posts_index.erb`、
  `posts_show.erb`、`posts_new.erb`、`posts_not_found.erb` をすべてフラットな
  ファイル名で配置（homura の compile-erb はサブディレクトリにも対応するが、
  このアプリではフラットスタイルを採用）。
- `Sinatra::Helpers#uri` 経由の `redirect "/posts/#{id}"` — `[303, ...]` のような
  Rack タプルを使った回避策は不要。
- `<%= h(post[:body]).gsub("\n", "<br>") %>` という標準的なパターンによる本文レンダリング。

## ルート

| Method | Path | 役割 |
|---|---|---|
| `GET`  | `/` | 投稿を全件一覧表示（新着順）。初回リクエスト時に 2 件のデモ投稿でシードされる。 |
| `GET`  | `/posts/:id` | 単一の投稿を表示するか、`status 404` で 404 ビューを表示する。 |
| `GET`  | `/posts/new` | 新規投稿フォーム。 |
| `POST` | `/posts` | D1 に INSERT して `redirect "/posts/#{meta['last_row_id']}"` する。 |
| `POST` | `/posts/:id/delete` | 行を削除して `redirect '/'` する。 |

## ディレクトリ構成

```
blog/
├── Gemfile               # public gems only
├── Rakefile              # + db:migrate:{compile,local,remote}
├── wrangler.toml         # D1 binding "DB" → database "blog"
├── app/app.rb            # Sinatra app + ensure_seed!
├── views/
│   ├── layout.erb
│   ├── posts_index.erb
│   ├── posts_show.erb
│   ├── posts_new.erb
│   └── posts_not_found.erb
├── db/migrate/
│   ├── 001_create_posts.rb
│   └── 001_create_posts.sql
└── public/robots.txt
```

## コードのハイライト

```ruby
get '/posts/:id' do
  ensure_seed!
  @post = db.get_first_row(
    'SELECT id, title, body, created_at FROM posts WHERE id = ?',
    [params[:id].to_i]
  )

  if @post
    erb :posts_show
  else
    status 404
    erb :posts_not_found
  end
end

post '/posts' do
  meta = db.execute_insert(
    'INSERT INTO posts (title, body, created_at) VALUES (?, ?, ?)',
    [params[:title].to_s, params[:body].to_s, Time.now.to_i]
  )
  redirect "/posts/#{meta['last_row_id']}"
end

post '/posts/:id/delete' do
  db.execute('DELETE FROM posts WHERE id = ?', [params[:id].to_i])
  redirect '/'
end
```

`meta['last_row_id']` がハッシュの **トップレベル** にあるのは、
`homura-runtime` 0.2.16 が `flatten_meta` の中で背後の Promise を await し、
D1 のネストした `meta` オブジェクトから `last_row_id` / `changes` /
`rows_read` / `rows_written` を引き上げているからである。

## 起動方法

```bash
cd examples/blog
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://blog.localhost:1355/
```

404 経路の確認:

```bash
curl -sS -i http://blog.localhost:1355/posts/9999 | head -1
# HTTP/1.1 404 Not Found
```

書き込み経路の確認:

```bash
curl -sS -i -X POST http://blog.localhost:1355/posts \
     -d 'title=Hello&body=Two%0Alines'
# HTTP/1.1 303 See Other
# location: http://blog.localhost:1355/posts/3

curl -sS    http://blog.localhost:1355/posts/3
# <p>Two<br>lines</p>

curl -sS -i -X POST http://blog.localhost:1355/posts/3/delete
# HTTP/1.1 303 See Other
# location: http://blog.localhost:1355/
```

## デプロイ

```bash
npx wrangler d1 create blog
# 発行された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
