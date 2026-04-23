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

runtime_names = CloudflareWorkers::BuildSupport::RUNTIME_GEM_NAMES
sinatra_names = CloudflareWorkers::BuildSupport::SINATRA_GEM_NAMES

ok = assert('prefers homura-runtime when both runtime aliases are loaded') do
  specs = {
    'cloudflare-workers-runtime' => FakeSpec.new('/tmp/old-runtime'),
    'homura-runtime' => FakeSpec.new('/tmp/new-runtime')
  }
  spec = CloudflareWorkers::BuildSupport.loaded_spec(*runtime_names, loaded_specs: specs)
  raise "expected /tmp/new-runtime, got #{spec&.full_gem_path}" unless spec&.full_gem_path == '/tmp/new-runtime'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('falls back to legacy runtime alias when needed') do
  specs = { 'cloudflare-workers-runtime' => FakeSpec.new('/tmp/old-runtime') }
  lib = CloudflareWorkers::BuildSupport.gem_lib(*runtime_names, loaded_specs: specs)
  raise "expected legacy lib path, got #{lib}" unless lib == '/tmp/old-runtime/lib'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves sinatra-homura before legacy sinatra alias') do
  specs = {
    'sinatra-cloudflare-workers' => FakeSpec.new('/tmp/old-sinatra'),
    'sinatra-homura' => FakeSpec.new('/tmp/new-sinatra')
  }
  lib = CloudflareWorkers::BuildSupport.gem_lib(*sinatra_names, loaded_specs: specs)
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

ok = assert('matches legacy runtime path dependency in Gemfile') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.expand_path('../vendor', dir))
    File.write(File.join(dir, 'Gemfile'), "gem 'cloudflare-workers-runtime', path: '../gems/homura-runtime'\n")
    vendor = CloudflareWorkers::BuildSupport.vendor_from_gemfile(dir)
    expected = File.expand_path('../vendor', dir)
    raise "expected #{expected}, got #{vendor}" unless vendor&.to_s == expected
  end
end
passed += 1 if ok
failed += 1 unless ok

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
