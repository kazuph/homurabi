# minimal-sinatra-with-db

Smallest Sinatra-on-Workers app that reads from D1 through **sequel-d1**.

## Prerequisites

- Ruby 3.4+, `bundle install` in this directory
- Node + `wrangler` (or use `npx wrangler`)
- A Cloudflare D1 database (replace `database_id` in `wrangler.toml`)

## Build the Worker bundle

From the **homura repository root** (this example only ships Ruby sources; the Opal compile command matches homura):

```bash
OPAL_PREFORK_DISABLE=1 bundle exec opal -c -E --esm --no-source-map \
  -I examples/minimal-sinatra-with-db \
  -I gems/homura-runtime/lib \
  -I gems/sinatra-homura/lib \
  -I gems/sequel-d1/lib \
  -I lib -I vendor -I build \
  -r opal_patches -r cloudflare_workers \
  -o build/minimal-sinatra-with-db.mjs \
  examples/minimal-sinatra-with-db/app.rb
```

For day-to-day work, copy the `-I` flags from homura `package.json` `build:opal` and point the entry file at `app.rb` here.

## Migrations

```bash
# from homura root, after bundle install
bundle exec homura db:migrate:compile examples/minimal-sinatra-with-db/db/migrations --out examples/minimal-sinatra-with-db/db/migrations
CLOUDFLARE_D1_DATABASE=minimal-sinatra-with-db bundle exec homura db:migrate:apply
```

## Quick check

- `GET /` — plain text hello
- `GET /users` — JSON rows from `users` via `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` (or `d1: env['cloudflare.env'].DB` for a raw binding)
