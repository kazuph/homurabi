require_relative 'lib/opal/version'

Gem::Specification.new do |spec|
  spec.name         = 'opal'
  spec.version      = Opal::VERSION
  spec.author       = ['Elia Schito', 'meh.', 'Adam Beynon']
  spec.email        = ['elia@schito.me', 'meh@schizofreni.co']

  spec.summary      = %{Ruby runtime and core library for JavaScript}
  spec.description  = %{Opal is a Ruby to JavaScript compiler. It is source-to-source, making it fast as a runtime. Opal includes a compiler (which can be run in any browser), a corelib and runtime implementation. The corelib/runtime is also very small.}
  spec.homepage     = 'https://opalrb.com'
  spec.license      = 'MIT'

  spec.metadata["homepage_uri"]          = "https://opalrb.com/"
  spec.metadata["bug_tracker_uri"]       = "https://github.com/opal/opal/issues"
  spec.metadata["changelog_uri"]         = "https://github.com/opal/opal/blob/v#{spec.version}/CHANGELOG.md"
  spec.metadata["readme_uri"]            = "https://github.com/opal/opal/blob/v#{spec.version}/README.md"
  spec.metadata["api_documentation_uri"] = "http://opalrb.com/docs/api/v#{spec.version}/index.html"
  spec.metadata["guides_uri"]            = "http://opalrb.com/docs/guides/v#{spec.version}/index.html"
  spec.metadata["chat_uri"]              = "https://gitter.im/opal/opal"
  spec.metadata["source_code_uri"]       = "https://github.com/opal/opal"

  # homurabi patch: vendor/opal-gem/ is not its own git repo (it's inside the
  # homurabi repo), so upstream's `git ls-files` returns files from the outer
  # repo and misses exe/. Use Dir.glob instead.
  files = Dir.chdir(__dir__) {
    Dir.glob('**/*', File::FNM_DOTMATCH).reject do |f|
      File.directory?(f) || File.symlink?(f) ||
        f.start_with?('.git/') || f == '.git' ||
        f.start_with?('vendor/bundle/')
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
