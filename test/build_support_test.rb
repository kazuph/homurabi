# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../gems/homura-runtime/lib', __dir__))
require 'homura/runtime/build_support'

FakeSpec = Struct.new(:full_gem_path) do
  # `BuildSupport.opal_gem_paths` (added in homura-runtime 0.2.25)
  # iterates `Gem.loaded_specs.each_value` and reads `spec.name` /
  # `spec.metadata` to decide whether a gem opts in to the auto-await
  # pass. Unit-test FakeSpecs must expose the same surface so that
  # ordinary `loaded_specs:` lookup tests don't blow up.
  def name
    full_gem_path.to_s.split('/').last.to_s
  end

  def metadata
    {}
  end
end

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

runtime_name = HomuraRuntime::BuildSupport::RUNTIME_GEM_NAME
sinatra_name = HomuraRuntime::BuildSupport::SINATRA_GEM_NAME
sequel_name = HomuraRuntime::BuildSupport::SEQUEL_D1_GEM_NAME

ok = assert('resolves homura-runtime from loaded specs') do
  specs = { 'homura-runtime' => FakeSpec.new('/tmp/new-runtime') }
  spec = HomuraRuntime::BuildSupport.loaded_spec(runtime_name, loaded_specs: specs)
  raise "expected /tmp/new-runtime, got #{spec&.full_gem_path}" unless spec&.full_gem_path == '/tmp/new-runtime'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves homura-runtime lib path') do
  specs = { 'homura-runtime' => FakeSpec.new('/tmp/new-runtime') }
  lib = HomuraRuntime::BuildSupport.gem_lib(runtime_name, loaded_specs: specs)
  raise "expected /tmp/new-runtime/lib, got #{lib}" unless lib == '/tmp/new-runtime/lib'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves sinatra-homura lib path') do
  specs = { 'sinatra-homura' => FakeSpec.new('/tmp/new-sinatra') }
  lib = HomuraRuntime::BuildSupport.gem_lib(sinatra_name, loaded_specs: specs)
  raise "expected /tmp/new-sinatra/lib, got #{lib}" unless lib == '/tmp/new-sinatra/lib'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('resolves packaged homura-runtime vendor path') do
  Dir.mktmpdir do |dir|
    specs = { 'homura-runtime' => FakeSpec.new(dir) }
    FileUtils.mkdir_p(File.join(dir, 'vendor'))
    vendor = HomuraRuntime::BuildSupport.gem_vendor(runtime_name, loaded_specs: specs)
    expected = File.join(dir, 'vendor')
    raise "expected #{expected}, got #{vendor}" unless vendor == expected
  end
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('returns nil when packaged vendor path is absent') do
  specs = { 'sinatra-homura' => FakeSpec.new('/tmp/new-sinatra') }
  vendor = HomuraRuntime::BuildSupport.gem_vendor(sinatra_name, loaded_specs: specs)
  raise "expected nil, got #{vendor.inspect}" unless vendor.nil?
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('matches homura-runtime path dependency in Gemfile') do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.expand_path('../vendor', dir))
    File.write(File.join(dir, 'Gemfile'), "gem 'homura-runtime', path: '../gems/homura-runtime'\n")
    vendor = HomuraRuntime::BuildSupport.vendor_from_gemfile(dir)
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

    target = HomuraRuntime::BuildSupport.ensure_standalone_runtime(dir, loaded_specs: specs)
    expected = File.join(dir, 'build', 'cf-runtime')
    raise "expected #{expected}, got #{target}" unless target.to_s == expected
    raise 'missing setup-node-crypto.mjs' unless File.read(File.join(expected, 'setup-node-crypto.mjs')) == "setup\n"
    raise 'missing worker_module.mjs' unless File.read(File.join(expected, 'worker_module.mjs')) == "worker\n"
  end
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('standalone load paths prepend packaged sequel-d1 vendor before lib when with_db') do
  Dir.mktmpdir do |dir|
    runtime_root = File.join(dir, 'runtime')
    sinatra_root = File.join(dir, 'sinatra')
    sequel_root = File.join(dir, 'sequel-d1')
    app_root = File.join(dir, 'app')
    [runtime_root, sinatra_root, sequel_root, app_root].each { |path| FileUtils.mkdir_p(path) }
    FileUtils.mkdir_p(File.join(runtime_root, 'vendor'))
    FileUtils.mkdir_p(File.join(sequel_root, 'vendor'))
    specs = {
      'homura-runtime' => FakeSpec.new(runtime_root),
      'sinatra-homura' => FakeSpec.new(sinatra_root),
      'sequel-d1' => FakeSpec.new(sequel_root)
    }
    load_paths = HomuraRuntime::BuildSupport.standalone_load_paths(app_root, with_db: true, loaded_specs: specs)
    sequel_vendor = File.join(sequel_root, 'vendor')
    sequel_lib = File.join(sequel_root, 'lib')
    raise "missing #{sequel_vendor}" unless load_paths.include?(sequel_vendor)
    raise "missing #{sequel_lib}" unless load_paths.include?(sequel_lib)
    raise "vendor should precede lib: #{load_paths.inspect}" unless load_paths.index(sequel_vendor) < load_paths.index(sequel_lib)
  end
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('derives standalone namespaces from project name') do
  templates = HomuraRuntime::BuildSupport.standalone_namespace('/tmp/demo-app', 'Templates')
  assets = HomuraRuntime::BuildSupport.standalone_namespace('/tmp/demo-app', 'Assets')
  raise "expected DemoAppTemplates, got #{templates}" unless templates == 'DemoAppTemplates'
  raise "expected DemoAppAssets, got #{assets}" unless assets == 'DemoAppAssets'
end
passed += 1 if ok
failed += 1 unless ok

ok = assert('prefixes standalone namespaces that would start with digits') do
  namespace = HomuraRuntime::BuildSupport.standalone_namespace('/tmp/123-app', 'Templates')
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
