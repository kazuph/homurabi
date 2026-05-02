# sequel-d1

Sequel **`:d1`** adapter and Opal/Cloudflare Workers glue for [Cloudflare D1](https://developers.cloudflare.com/d1/).

## Quick start (Sinatra on Workers)

```ruby
require 'sequel'

DB = nil

get '/users' do
  DB ||= Sequel.connect(adapter: :d1, d1: d1)
  content_type 'application/json'
  DB[:users].order(:id).all.to_json
end
```

`d1:` must respond to `prepare(sql)` returning a statement that supports `bind(*args)`, `all`, and `run` (same contract as the JavaScript D1 API). In a homura route, the `d1` helper is the usual choice.

## Opal build paths

`homura build --standalone --with-db` now wires this up for you.
If you invoke `opal` manually, add the gem's packaged `vendor/` before its
`lib/` so `require 'sequel'` resolves to the bundled Opal-compatible entrypoint:

```text
-I gems/sequel-d1/vendor -I gems/sequel-d1/lib -I lib -I vendor
```

## Migrations (`homura db:migrate:*`)

Compile Ruby migration files to wrangler-compatible `.sql`:

```bash
bundle exec homura db:migrate:compile db/migrate --out db/migrate
```

Apply (uses `WRANGLER_BIN` or `wrangler`; database from `--database` or `CLOUDFLARE_D1_DATABASE`):

```bash
bundle exec homura db:migrate:apply --database homura-db
bundle exec homura db:migrate:apply --remote --database homura-db
```

Generated `--with-db` apps wire this up as:

```bash
bundle exec rake db:migrate:compile
bundle exec rake db:migrate:local
bundle exec rake db:migrate:remote
```

Generated and documented apps also keep `compatibility_flags = ["nodejs_compat"]`
in `wrangler.toml`, because the runtime depends on `node:crypto`.

## License

MIT. See the repository `LICENSE`.
