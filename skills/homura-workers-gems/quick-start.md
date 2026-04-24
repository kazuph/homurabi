# Quick start

## Fastest current path

1. Scaffold a new app with `bundle exec homura new myapp`.
2. Add `--with-db` if the app should use D1 through Sequel.
3. In generated apps, use `bundle exec rake dev`, `bundle exec rake build`, and `bundle exec rake deploy`.
4. Drop down to `bundle exec homura build` only when you are debugging the lower-level build pipeline.
5. Standard layout is `app/app.rb` plus `config.ru`; `app/hello.rb` is no longer required.

## Minimal Gemfile shape

```ruby
source 'https://rubygems.org'

gem 'opal-homura', '= 1.8.3.rc1.3', require: 'opal'
gem 'homura-runtime', '= 0.2.7'
gem 'sinatra-homura', '= 0.2.11'
gem 'sequel-d1', '= 0.2.6' # only if D1 / Sequel is needed
```

## Build / deploy flow

1. Scaffold or write a Sinatra app.
2. Prefer generated Rake tasks as the user-facing workflow.
3. If you are wiring a D1/Sequel app by hand, use `bundle exec homura build --standalone --with-db`.
4. Set `wrangler.toml` `main = "build/worker.entrypoint.mjs"`.
5. Deploy with Wrangler.

If `homura build` fails during Opal compile, read `build/opal.stderr.log` first.

## Minimal runtime snippet

```ruby
# app/app.rb
require 'sinatra/cloudflare_workers'
require 'sequel'

class App < Sinatra::Base
  get '/users' do
    db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    content_type 'application/json'
    db[:users].all.to_json
  end
end
```

```ruby
# config.ru
require_relative 'app/app'

run App
```

For the common binding/helper paths above, homura's build step auto-inserts
`.__await__` under the hood. Manual `.__await__` is mainly for raw Promise work
outside those registered patterns.
