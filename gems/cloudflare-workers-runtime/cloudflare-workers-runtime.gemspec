# frozen_string_literal: true

require_relative 'lib/cloudflare_workers/version'

Gem::Specification.new do |spec|
  spec.name = 'cloudflare-workers-runtime'
  spec.version = CloudflareWorkers::VERSION
  spec.authors = ['Kazuhiro NISHIYAMA']
  spec.summary = 'Cloudflare Workers + Opal runtime core (Rack dispatch, bindings, patches)'
  spec.description = <<~DESC
    Sinatra-free core for running Opal-compiled Ruby on Cloudflare Workers:
    Rack handler, D1/KV/R2/AI/Queue/Durable Object adapters, multipart/streaming,
    and Opal corelib patches. Use with the `opal` gem and a Module Worker
    (`runtime/worker.mjs` in this gem).
  DESC
  spec.homepage = 'https://github.com/kazuph/homurabi'
  spec.required_ruby_version = '>= 3.4.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main/gems/cloudflare-workers-runtime"

  # Consumer-facing snippets (e.g. templates/wrangler.toml.example) ship with the gem —
  # `templates/**/*` must remain in this glob so rubygems packaging does not omit them.
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'runtime/**/*', 'exe/**/*', 'bin/*', 'docs/**/*', 'templates/**/*', 'README.md', 'CHANGELOG.md'].select { |f| File.file?(f) }
  end
  spec.require_paths = ['lib']
  spec.bindir = 'bin'
  spec.executables = ['cloudflare-workers-build']

  # Exact pin: homurabi verifies against vendor/opal-gem 1.8.3.rc1 (Ruby 3.4); rubygems.org lists 1.8.2 only.
  spec.add_runtime_dependency 'opal', '= 1.8.3.rc1'

  # parser is build-time only (auto-await analyzer). Not needed at Workers runtime.
  spec.add_development_dependency 'parser', '~> 3.3'
end
