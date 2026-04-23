# frozen_string_literal: true

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

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
