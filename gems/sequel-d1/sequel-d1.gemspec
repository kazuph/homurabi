# frozen_string_literal: true

require_relative 'lib/sequel/d1/version'

Gem::Specification.new do |spec|
  spec.name = 'sequel-d1'
  spec.version = Sequel::D1::VERSION
  spec.authors = ['Kazuhiro Homma']
  spec.summary = 'Sequel adapter for Cloudflare D1 (Opal / Workers) + migration compile CLI'
  spec.description = <<~DESC
    Sequel `:d1` adapter and Opal compatibility patches for Cloudflare D1.
    Pass a duck-typed D1 binding to `Sequel.connect(adapter: :d1, d1: binding)`.
    Includes the `homura db:migrate:*` tooling to compile Sequel migration DSL to wrangler SQL.
  DESC
  spec.homepage = 'https://github.com/kazuph/homura'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4.0'

  gem_path = 'gems/sequel-d1'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main/#{gem_path}"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/CHANGELOG.md"
  spec.metadata['readme_uri'] = "#{spec.homepage}/blob/main/#{gem_path}/README.md"
  spec.metadata['documentation_uri'] = 'https://homura.kazu-san.workers.dev/docs/sequel-d1'

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'vendor/**/*', 'exe/*', 'README.md', 'CHANGELOG.md'].select { |f| File.file?(f) }
  end
  spec.require_paths = ['lib']
  spec.bindir = 'bin'
  spec.executables = []

  spec.add_runtime_dependency 'homura-runtime', '~> 0.3'
  spec.add_runtime_dependency 'opal-homura', '= 1.8.3.rc1.5'
  spec.add_runtime_dependency 'sequel', '~> 5.0'
  spec.add_runtime_dependency 'sqlite3', '~> 2.0'
end
