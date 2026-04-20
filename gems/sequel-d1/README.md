# sequel-d1

Sequel **`:d1`** adapter and Opal/Cloudflare Workers glue for [Cloudflare D1](https://developers.cloudflare.com/d1/).

## Quick start (Sinatra on Workers)

```ruby
require 'sequel'

DB = nil

get '/users' do
  DB ||= Sequel.connect(adapter: :d1, d1: env['cloudflare.env'].DB)
  content_type 'application/json'
  # On Opal/Workers, Dataset#all returns a Promise — resolve before JSON.
  DB[:users].order(:id).all.__await__.to_json
end
```

`d1:` must respond to `prepare(sql)` returning a statement that supports `bind(*args)`, `all`, and `run` (same contract as the JavaScript D1 API). The Ruby wrapper from `cloudflare-workers-runtime` (`env['cloudflare.DB']`) is the usual choice.

## Opal build paths

Add the gem `lib` directory to Opal `-I` **before** `vendor` so `require 'sequel'` resolves your vendored `sequel.rb`, which then loads `sequel_opal_*` and `sequel/adapters/d1` from this gem:

```text
-I gems/sequel-d1/lib -I lib -I vendor
```

## Migrations (`cloudflare-workers-migrate`)

Compile Ruby migration files to wrangler-compatible `.sql`:

```bash
bundle exec cloudflare-workers-migrate compile db/migrations
```

Apply (uses `WRANGLER_BIN` or `wrangler`; database from `--database` or `CLOUDFLARE_D1_DATABASE`):

```bash
bundle exec cloudflare-workers-migrate apply --database homurabi-db
bundle exec cloudflare-workers-migrate apply --remote --database homurabi-db
```

## License

Same as the homurabi repository (personal project).
