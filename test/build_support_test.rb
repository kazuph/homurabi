# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../gems/homura-runtime/lib', __dir__))
require 'cloudflare_workers/build_support'

FakeSpec = Struct.new(:full_gem_path)

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

runtime_name = CloudflareWorkers::BuildSupport::RUNTIME_GEM_NAME
sinatra_name = CloudflareWorkers::BuildSupport::SINATRA_GEM_NAME

ok = assert('resolves homura-runtime from loaded specs') do
  specs = { 'homura-runtime' => FakeSpec.new('/tmp/new-runtime') }
  spec = CloudflareWorkers::BuildSupport.loaded_spec(runtime_name, loaded_specs: specs)
  raise "expected /tmp/new-runtime, got #{spec&.full_gem_path}" unless spec&.full_gem_path == '/tmp/new-runtime'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves homura-runtime lib path') do
  specs = { 'homura-runtime' => FakeSpec.new('/tmp/new-runtime') }
  lib = CloudflareWorkers::BuildSupport.gem_lib(runtime_name, loaded_specs: specs)
  raise "expected /tmp/new-runtime/lib, got #{lib}" unless lib == '/tmp/new-runtime/lib'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves sinatra-homura lib path') do
  specs = { 'sinatra-homura' => FakeSpec.new('/tmp/new-sinatra') }
  lib = CloudflareWorkers::BuildSupport.gem_lib(sinatra_name, loaded_specs: specs)
  raise "expected /tmp/new-sinatra/lib, got #{lib}" unless lib == '/tmp/new-sinatra/lib'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('matches homura-runtime path dependency in Gemfile') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.expand_path('../vendor', dir))
    File.write(File.join(dir, 'Gemfile'), "gem 'homura-runtime', path: '../gems/homura-runtime'\n")
    vendor = CloudflareWorkers::BuildSupport.vendor_from_gemfile(dir)
    expected = File.expand_path('../vendor', dir)
    raise "expected #{expected}, got #{vendor}" unless vendor&.to_s == expected
  end
end
passed += 1 if ok
failed += 1 unless ok

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
