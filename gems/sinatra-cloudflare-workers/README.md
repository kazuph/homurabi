# sinatra-cloudflare-workers

Opal-oriented Sinatra compatibility patches (`sinatra_opal_patches.rb`) and extensions (`Sinatra::JwtAuth`, `Sinatra::Scheduled`, `Sinatra::Queue`) used by [homurabi](https://github.com/kazuph/homurabi) on Cloudflare Workers.

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

## ERB precompile

```bash
bundle exec cloudflare-workers-erb-compile --input views --output build/templates.rb --namespace MyTemplates
```

See `templates/Rakefile.example` for Rake integration.

## License

Same as the homurabi repository (private / personal use).
