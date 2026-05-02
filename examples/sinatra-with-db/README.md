# sinatra-with-db

Smallest Sinatra-on-Workers app that reads from D1 through **sequel-d1**.

## Prerequisites

- Ruby 3.4+, `bundle install` in this directory
- Node + `wrangler` (or use `npx wrangler`)
- A Cloudflare D1 database — `npx wrangler d1 create sinatra-with-db` and paste the returned UUID into `wrangler.toml`'s `database_id`

## Build / dev / deploy

```bash
bundle exec rake build       # bundle exec homura build --standalone --with-db
bundle exec rake dev         # build + npx wrangler dev --local
bundle exec rake deploy      # build + npx wrangler deploy
```

Or via npm (the same rake tasks under the hood): `npm run build`, `npm run dev`, `npm run deploy`.

## Migrations

```bash
bundle exec rake db:migrate:compile   # Sequel migrations -> Wrangler SQL in db/migrations/
bundle exec rake db:migrate:local     # apply to local D1 (compile + apply)
bundle exec rake db:migrate:remote    # apply to remote D1 (compile + apply --remote)
```

The remote tasks honor `CLOUDFLARE_D1_DATABASE` env var; the default matches the `database_name` in `wrangler.toml`.

## Quick check

- `GET /` — plain text hello
- `GET /users` — JSON rows from `users` via `Sequel.connect(adapter: :d1, d1: d1)`
