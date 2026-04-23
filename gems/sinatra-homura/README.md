# sinatra-homura

Opal-oriented Sinatra compatibility patches (`sinatra_opal_patches.rb`) and extensions (`Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`) used by [homura](https://github.com/kazuph/homura) on Cloudflare Workers.

## Usage

```ruby
require 'sinatra/cloudflare_workers'
require 'sequel' # etc.

class App < Sinatra::Base
  register Sinatra::JwtAuth
  # ...
end

run App # optional if `App` is defined; a fallback registers the Rack handler at exit
```

## Scaffolding

```bash
bundle exec homura new myapp
```

`cloudflare-workers-new` remains available as a compatibility alias, but
`homura new` is the preferred entrypoint.

## ERB precompile

```bash
bundle exec cloudflare-workers-erb-compile --input views --output build/templates.rb --namespace MyTemplates
```

See `templates/Rakefile.example` for Rake integration.

## License

MIT. See the repository `LICENSE`.
