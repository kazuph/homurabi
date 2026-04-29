# frozen_string_literal: true

require_relative 'lib/sinatra/inertia/version'

Gem::Specification.new do |spec|
  spec.name = 'sinatra-inertia'
  spec.version = Sinatra::Inertia::VERSION
  spec.authors = ['Kazuhiro Homma']
  spec.summary = 'Sinatra adapter for Inertia.js (v2 protocol)'
  spec.description = <<~DESC
    A Sinatra extension that implements the full Inertia.js v2 wire protocol:
    page-object responses, version mismatch detection (409 + X-Inertia-Location),
    partial reloads, deferred / lazy / always / optional / merge props,
    encrypted history, redirect 303 handling, and error/flash session sweeps.

    Pure Sinatra-compatible: depends only on `sinatra` and `rack`. Runs on MRI
    Ruby and on the homura Cloudflare Workers + Opal stack.
  DESC
  spec.homepage = 'https://github.com/kazuph/homura'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  gem_path = 'gems/sinatra-inertia'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main/#{gem_path}"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/CHANGELOG.md"
  spec.metadata['readme_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/README.md"

  # Opt-in to homura-runtime's auto-await pass: when this gem is
  # installed alongside homura-runtime (>= 0.2.25), `homura build`
  # automatically adds our `lib/` to the Opal load path and runs the
  # auto-await analyzer over our source so async chains
  # (`db[:foo].all` returning a Promise inside a route Proc, etc.)
  # resolve transparently. No-op when consumed by plain MRI Sinatra apps.
  spec.metadata['homura.auto_await'] = 'true'

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'README.md', 'CHANGELOG.md', 'LICENSE'].select { |f| File.file?(f) }
  end
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'sinatra', '>= 3.0', '< 5.0'
  spec.add_runtime_dependency 'rack', '>= 2.0', '< 4.0'
end
