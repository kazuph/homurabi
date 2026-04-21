# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'sinatra-cloudflare-workers'
  spec.version = '0.1.0'
  spec.authors = ['Kazuhiro NISHIYAMA']
  spec.summary = 'Sinatra + Opal patches and extensions for Cloudflare Workers'
  spec.description = <<~DESC
    Opal compatibility patches for upstream Sinatra, plus homurabi JWT / Cron / Queue
    extensions. Depends on cloudflare-workers-runtime. Consumers typically vendor
    sinatra and compile with Opal; this gem ships library Ruby only.
  DESC
  spec.homepage = 'https://github.com/kazuph/homurabi'
  spec.required_ruby_version = '>= 3.4.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main/gems/sinatra-cloudflare-workers"

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*', 'bin/*', 'templates/**/*', 'README.md', 'CHANGELOG.md'].select { |f| File.file?(f) }
  end
  spec.require_paths = ['lib']
  spec.bindir = 'bin'
  spec.executables = %w[cloudflare-workers-erb-compile cloudflare-workers-new]

  spec.add_runtime_dependency 'cloudflare-workers-runtime', '>= 0.1'
  spec.add_runtime_dependency 'opal', '= 1.8.3.rc1'
end
