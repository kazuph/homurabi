# blog

> A small **D1-backed blog** — index, detail, new-post form, **proper
> 404**, and delete. The 404 route is the load-bearing demo: it
> exercises the async-route status preservation in
> `sinatra-homura` 0.2.17.

## What this shows

- The full read/write Sinatra surface against Cloudflare D1 without
  Sequel — `db.execute`, `db.execute_insert`, `db.get_first_row`.
- `status 404; erb :posts_not_found` actually returns **404**, not 200.
  Earlier sinatra-homura versions snapshotted `response.status` before
  the awaited continuation finished and overwrote it on the way out;
  0.2.17 captures the final triple after every Promise resolves.
- A normal Sinatra layout with sub-templates: `posts_index.erb`,
  `posts_show.erb`, `posts_new.erb`, `posts_not_found.erb`, all flat
  filenames (homura's compile-erb supports subdirectories too, but this
  app sticks with the flat style).
- `redirect "/posts/#{id}"` via `Sinatra::Helpers#uri` — no
  `[303, ...]` Rack-tuple workarounds.
- Body rendering with the standard `<%= h(post[:body]).gsub("\n", "<br>") %>`
  pattern.

## Routes

| Method | Path | What it does |
|---|---|---|
| `GET`  | `/` | List all posts (newest first), seeded with two demo entries on first request. |
| `GET`  | `/posts/:id` | Render a single post, or render the 404 view with `status 404`. |
| `GET`  | `/posts/new` | New-post form. |
| `POST` | `/posts` | Insert into D1 and `redirect "/posts/#{meta['last_row_id']}"`. |
| `POST` | `/posts/:id/delete` | Delete the row and `redirect '/'`. |

## Layout

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

## Code highlights

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

`meta['last_row_id']` is at the **top** of the hash because
`homura-runtime` 0.2.16 awaits the underlying Promise inside
`flatten_meta` and then lifts `last_row_id` / `changes` /
`rows_read` / `rows_written` out of D1's nested `meta` object.

## Run it

```bash
cd examples/blog
bundle install
npm install

bundle exec rake db:migrate:local
bundle exec rake build
bundle exec rake dev
# → http://blog.localhost:1355/
```

Test the 404 path:

```bash
curl -sS -i http://blog.localhost:1355/posts/9999 | head -1
# HTTP/1.1 404 Not Found
```

Test the write path:

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

## Deploy

```bash
npx wrangler d1 create blog
# paste the new database_id into wrangler.toml
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
