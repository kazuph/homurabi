# Quick start

## Fastest current path

1. Scaffold a new app with `bundle exec homura new myapp`.
2. Add `--with-db` if the app should use D1 through Sequel.
3. In generated apps, use `bundle exec rake dev`, `bundle exec rake build`, and `bundle exec rake deploy`.
4. For `--with-db` scaffolds, use `bundle exec rake db:migrate:compile`, `bundle exec rake db:migrate:local`, and `bundle exec rake db:migrate:remote`.
5. Generated apps keep `wrangler.toml` `main = "build/worker.entrypoint.mjs"` and `compatibility_flags = ["nodejs_compat"]`.
6. Drop down to `bundle exec homura build` only when you are debugging the lower-level build pipeline.
7. Standard layout is `app/app.rb` plus `config.ru`; `app/hello.rb` is no longer required.

## Minimal Gemfile shape

```ruby
source 'https://rubygems.org'

gem 'opal-homura', '= 1.8.3.rc1.3', require: 'opal'
gem 'rake' # generated apps use this for build/dev/deploy
gem 'homura-runtime', '= 0.2.9'
gem 'sinatra-homura', '= 0.2.13'
gem 'sequel-d1', '= 0.2.7' # only if D1 / Sequel is needed
```

## Build / deploy flow

1. Scaffold or write a Sinatra app.
2. Prefer generated Rake tasks as the user-facing workflow.
3. If you are wiring a D1/Sequel app by hand, use `bundle exec homura build --standalone --with-db`.
4. In generated apps, keep `wrangler.toml` `main = "build/worker.entrypoint.mjs"` and `compatibility_flags = ["nodejs_compat"]`.
5. For D1, prefer `require 'sequel'` plus `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`.
6. Deploy with Wrangler.

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
`.__await__` under the hood. That includes the common Sequel helper shape
`def db; Sequel.connect(adapter: :d1, d1: env['cloudflare.DB']); end`, normal
`config.ru` files with `require_relative 'app/app'`, default `layout.erb`
application for `erb :index`, and awaited Sequel/D1 routes that still finish
with an ordinary `redirect`. Manual `.__await__` is mainly for raw Promise work
outside those registered patterns.
