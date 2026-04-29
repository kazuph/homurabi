# sinatra-homura

Opal-oriented Sinatra compatibility patches (`sinatra_opal_patches.rb`) and extensions (`Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`) used by [homura](https://github.com/kazuph/homura) on Cloudflare Workers.

## Usage

`sinatra-homura` does not require an explicit `require` line beyond the
canonical Sinatra entry points — adding `gem 'sinatra-homura'` to your
`Gemfile` is enough. The vendored Sinatra entry points (`sinatra.rb` /
`sinatra/base.rb`) auto-load the homura adapter at the bottom, in the
order: `homura/runtime` → Opal/Sinatra patches → `Sinatra::Base` →
JwtAuth / Scheduled / Queue extensions.

Classic top-level Sinatra (the canonical sinatrarb.com snippet shape):

```ruby
require 'sinatra'

get '/frank-says' do
  'Put this in your pipe & smoke it!'
end
```

Modular Sinatra (`bundle exec homura new` scaffolds this layout):

```ruby
require 'sinatra/base'

class App < Sinatra::Base
  register Sinatra::JwtAuth
  # ...
end

run App
```

In neither shape does user code reach for a Cloudflare-flavoured
require. Everything Workers-specific lives in `homura-runtime` and is
auto-loaded by sinatra-homura.

## Scaffolding

```bash
bundle exec homura new myapp
```

Generated apps should treat `bundle exec rake build`, `bundle exec rake dev`,
and `bundle exec rake deploy` as the primary day-to-day workflow. `homura`
stays available as the lower-level implementation surface behind that Rakefile.

## ERB precompile

```bash
bundle exec homura erb:compile --input views --output build/templates.rb --namespace MyTemplates
```

See `templates/Rakefile.example` for Rake integration.

## License

MIT. See the repository `LICENSE`.
