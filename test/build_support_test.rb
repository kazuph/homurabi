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

ok = assert('resolves packaged homura-runtime vendor path') do
  Dir.mktmpdir do |dir|
    specs = { 'homura-runtime' => FakeSpec.new(dir) }
    FileUtils.mkdir_p(File.join(dir, 'vendor'))
    vendor = CloudflareWorkers::BuildSupport.gem_vendor(runtime_name, loaded_specs: specs)
    expected = File.join(dir, 'vendor')
    raise "expected #{expected}, got #{vendor}" unless vendor == expected
  end
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('returns nil when packaged vendor path is absent') do
  specs = { 'sinatra-homura' => FakeSpec.new('/tmp/new-sinatra') }
  vendor = CloudflareWorkers::BuildSupport.gem_vendor(sinatra_name, loaded_specs: specs)
  raise "expected nil, got #{vendor.inspect}" unless vendor.nil?
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

ok = assert('copies standalone runtime files into cf-runtime') do
  Dir.mktmpdir do |dir|
    runtime_root = File.join(dir, 'runtime-gem')
    specs = { 'homura-runtime' => FakeSpec.new(runtime_root) }
    FileUtils.mkdir_p(File.join(runtime_root, 'runtime'))
    File.write(File.join(runtime_root, 'runtime', 'setup-node-crypto.mjs'), "setup\n")
    File.write(File.join(runtime_root, 'runtime', 'worker_module.mjs'), "worker\n")

    target = CloudflareWorkers::BuildSupport.ensure_standalone_runtime(dir, loaded_specs: specs)
    raise "expected #{File.join(dir, 'cf-runtime')}, got #{target}" unless target.to_s == File.join(dir, 'cf-runtime')
    raise 'missing setup-node-crypto.mjs' unless File.read(File.join(dir, 'cf-runtime', 'setup-node-crypto.mjs')) == "setup\n"
    raise 'missing worker_module.mjs' unless File.read(File.join(dir, 'cf-runtime', 'worker_module.mjs')) == "worker\n"
  end
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('derives standalone namespaces from project name') do
  templates = CloudflareWorkers::BuildSupport.standalone_namespace('/tmp/demo-app', 'Templates')
  assets = CloudflareWorkers::BuildSupport.standalone_namespace('/tmp/demo-app', 'Assets')
  raise "expected DemoAppTemplates, got #{templates}" unless templates == 'DemoAppTemplates'
  raise "expected DemoAppAssets, got #{assets}" unless assets == 'DemoAppAssets'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('prefixes standalone namespaces that would start with digits') do
  namespace = CloudflareWorkers::BuildSupport.standalone_namespace('/tmp/123-app', 'Templates')
  raise "expected App123AppTemplates, got #{namespace}" unless namespace == 'App123AppTemplates'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('homura-runtime gemspec packages vendor shims') do
  spec = Dir.chdir(File.expand_path('../gems/homura-runtime', __dir__)) do
    Gem::Specification.load('homura-runtime.gemspec')
  end
  raise 'missing vendor/digest.rb' unless spec.files.include?('vendor/digest.rb')
  raise 'missing vendor/cgi/escape.rb' unless spec.files.include?('vendor/cgi/escape.rb')
  raise 'missing vendor/rubygems/version.rb' unless spec.files.include?('vendor/rubygems/version.rb')
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('sinatra-homura gemspec packages vendored sinatra sources') do
  spec = Dir.chdir(File.expand_path('../gems/sinatra-homura', __dir__)) do
    Gem::Specification.load('sinatra-homura.gemspec')
  end
  raise 'missing vendor/sinatra/base.rb' unless spec.files.include?('vendor/sinatra/base.rb')
  raise 'missing vendor/jwt.rb' unless spec.files.include?('vendor/jwt.rb')
end
passed += 1 if ok
failed += 1 unless ok

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
