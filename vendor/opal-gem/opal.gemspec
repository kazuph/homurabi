require_relative 'lib/opal/version'

Gem::Specification.new do |spec|
  spec.name         = 'opal-homura'
  spec.version      = Opal::VERSION
  spec.author       = ['Elia Schito', 'meh.', 'Adam Beynon', 'Kazuhiro Homma']
  spec.email        = ['elia@schito.me', 'meh@schizofreni.co']

  spec.summary      = %{Patched Opal compiler/runtime for Cloudflare Workers}
  spec.description  = %{Forked Opal 1.8.3.rc1 with homura patches for Cloudflare Workers, modern Ruby 3.4 compatibility, and the Sinatra-on-Workers toolchain. Library require path remains `opal`.}
  spec.homepage     = 'https://github.com/kazuph/homura'
  spec.license      = 'MIT'

  gem_path = 'vendor/opal-gem'
  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/#{gem_path}/CHANGELOG.md"
  spec.metadata["readme_uri"]            = "#{spec.homepage}/blob/main/#{gem_path}/README.md"
  spec.metadata["source_code_uri"]       = "#{spec.homepage}/tree/main/#{gem_path}"
  spec.metadata["documentation_uri"]     = "https://homura.kazu-san.workers.dev/docs/architecture"

  # homura patch: vendor/opal-gem/ is not its own git repo (it's inside the
  # homura repo), so upstream's `git ls-files` returns files from the outer
  # repo and misses exe/. Use Dir.glob instead.
  files = Dir.chdir(__dir__) {
    Dir.glob('**/*', File::FNM_DOTMATCH).reject do |f|
      File.directory?(f) || File.symlink?(f) ||
        f.start_with?('.git/') || f == '.git' ||
        f.start_with?('vendor/bundle/') ||
        f.end_with?('.gem')
    end
  }

  spec.files         = files.grep_v(%r{^(test|spec|features)/})
  spec.test_files    = files.grep(%r{^(test|spec|features)/})
  spec.executables   = Dir.chdir(__dir__) { Dir.glob('exe/*').map { |f| File.basename(f) } }
  spec.bindir        = 'exe'
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 2.3'

  spec.add_dependency 'ast', '>= 2.3.0'
  spec.add_dependency 'base64', '>= 0.2.0'
  spec.add_dependency 'parser', ['~> 3.0', '>= 3.0.3.2']

  spec.add_development_dependency 'sourcemap', '~> 0.1.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.9'
  spec.add_development_dependency 'octokit', '~> 4.9'
  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rack-test'
  spec.add_development_dependency 'selenium-webdriver'
  spec.add_development_dependency 'benchmark-ips', '< 2.8'
  spec.add_development_dependency 'sinatra', '~> 3.2'
  spec.add_development_dependency 'rubocop', '~> 1.50'
  spec.add_development_dependency 'rubocop-performance', '~> 1.1'
  spec.add_development_dependency 'rack', '~> 2.2'
  spec.add_development_dependency 'webrick'
  spec.add_development_dependency 'benchmark_driver', '0.15.17' # version taken from test/cruby/common.mk
end
