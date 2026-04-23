# frozen_string_literal: true

require_relative 'lib/cloudflare_workers/version'

Gem::Specification.new do |spec|
  spec.name = 'homura-runtime'
  spec.version = CloudflareWorkers::VERSION
  spec.authors = ['Kazuhiro Homma']
  spec.summary = 'Cloudflare Workers + Opal runtime core (Rack dispatch, bindings, patches)'
  spec.description = <<~DESC
    Sinatra-free core for running Opal-compiled Ruby on Cloudflare Workers:
    Rack handler, D1/KV/R2/AI/Queue/Durable Object adapters, multipart/streaming,
    and Opal corelib patches. Use with the `opal` gem and a Module Worker
    (`runtime/worker.mjs` in this gem).
  DESC
  spec.homepage = 'https://github.com/kazuph/homura'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4.0'

  gem_path = 'gems/homura-runtime'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main/#{gem_path}"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/CHANGELOG.md"
  spec.metadata['readme_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/README.md"
  spec.metadata['documentation_uri'] = 'https://homura.kazu-san.workers.dev/docs/runtime'

  # Consumer-facing snippets (e.g. templates/wrangler.toml.example) ship with the gem —
  # `templates/**/*` must remain in this glob so rubygems packaging does not omit them.
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'vendor/**/*', 'runtime/**/*', 'exe/**/*', 'bin/*', 'docs/**/*', 'templates/**/*', 'README.md', 'CHANGELOG.md'].select { |f| File.file?(f) }
  end
  spec.require_paths = ['lib']
  spec.bindir = 'bin'
  spec.executables = []

  # Exact pin: homura verifies against the vendored Opal fork 1.8.3.rc1.3 for Ruby 3.4 compatibility.
  spec.add_runtime_dependency 'opal-homura', '= 1.8.3.rc1.3'

  # parser is required by the build pipeline (auto-await analyzer).
  spec.add_runtime_dependency 'parser', '~> 3.3'
end
