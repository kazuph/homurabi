# frozen_string_literal: true

require 'open3'
require 'rbconfig'

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

ok = assert('sequel-d1 gemspec packages vendored sequel sources') do
  spec = Dir.chdir(File.expand_path('../gems/sequel-d1', __dir__)) do
    Gem::Specification.load('sequel-d1.gemspec')
  end
  raise 'missing vendor/sequel.rb' unless spec.files.include?('vendor/sequel.rb')
  raise 'missing vendor/sequel/core.rb' unless spec.files.include?('vendor/sequel/core.rb')
  raise 'missing vendor/sequel/database/connecting.rb' unless spec.files.include?('vendor/sequel/database/connecting.rb')
end
passed += 1 if ok
failed += 1 unless ok

ok = assert("requiring packaged sequel registers the d1 adapter") do
  gem_root = File.expand_path('../gems/sequel-d1', __dir__)
  script = <<~'RUBY'
    gem_root = ARGV.fetch(0)
    $LOAD_PATH.unshift(File.join(gem_root, 'lib'))
    $LOAD_PATH.unshift(File.join(gem_root, 'vendor'))
    require 'sequel'
    raise 'd1 adapter not registered' unless Sequel::ADAPTER_MAP[:d1]
  RUBY
  out, status = Open3.capture2e(RbConfig.ruby, '-e', script, gem_root)
  raise out unless status.success?
end
passed += 1 if ok
failed += 1 unless ok

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
