# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

passed = 0
failed = 0

def assert(label)
  yield
  puts "PASS #{label}"
  true
rescue => e
  warn "FAIL #{label}: #{e.class}: #{e.message}"
  false
end

repo_root = File.expand_path('..', __dir__)
cli = File.join(repo_root, 'gems', 'sinatra-homura', 'bin', 'homura')

ok = assert('homura CLI shows new subcommand usage') do
  output = `bundle exec ruby #{cli} 2>&1`
  raise "unexpected success" if $?.success?
  raise output unless output.include?('usage: homura COMMAND')
  raise output unless output.include?('new APP_NAME [--with-db]')
end
passed += 1 if ok
failed += 1 unless ok

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'demo-app')
  ok = assert('homura new scaffolds a project') do
    Dir.chdir(repo_root) do
      system('bundle', 'exec', 'ruby', cli, 'new', app_dir) or raise 'homura new failed'
    end
    raise 'Gemfile missing' unless File.exist?(File.join(app_dir, 'Gemfile'))
    raise 'app/hello.rb missing' unless File.exist?(File.join(app_dir, 'app', 'hello.rb'))
    raise 'cf-runtime/setup-node-crypto.mjs missing' unless File.exist?(File.join(app_dir, 'cf-runtime', 'setup-node-crypto.mjs'))
  end
  passed += 1 if ok
  failed += 1 unless ok
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
