# Quick start

## Minimal Gemfile shape

```ruby
source 'https://rubygems.org'

gem 'opal-homura', '= 1.8.3.rc1.3', require: 'opal'
gem 'homura-runtime', '~> 0.2'
gem 'sinatra-homura', '~> 0.2'
gem 'sequel-d1', '~> 0.2' # only if D1 / Sequel is needed
```

If Bundler reports `revealed dependencies not in the API` for `homura-runtime`,
retry with `bundle install --full-index`.

## Build / deploy flow

1. Scaffold or write a Sinatra app.
2. For generated apps, prefer `bundle exec rake build`, `bundle exec rake dev`, and `bundle exec rake deploy`.
3. Use `homura` directly only when you are wiring or debugging the lower-level build surface.
4. If the app uses D1 through Sequel, build with `bundle exec homura build --standalone --with-db`.
5. Set `wrangler.toml` `main = "build/worker.entrypoint.mjs"`.
6. Deploy with Wrangler.

If `homura build` fails during Opal compile, read `build/opal.stderr.log` first.

## Minimal runtime snippet

```ruby
require 'sinatra/cloudflare_workers'
require 'sequel'

class App < Sinatra::Base
  get '/users' do
    db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    content_type 'application/json'
    db[:users].all.to_json
  end
end

run App
```

For the common binding/helper paths above, homura's build step auto-inserts
`.__await__` under the hood. Manual `.__await__` is mainly for raw Promise work
outside those registered patterns.
