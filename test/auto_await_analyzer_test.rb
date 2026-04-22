# frozen_string_literal: true

require_relative '../gems/homura-runtime/lib/cloudflare_workers/async_registry'
require_relative '../gems/homura-runtime/lib/cloudflare_workers/auto_await/analyzer'
require_relative '../gems/homura-runtime/lib/cloudflare_workers/auto_await/transformer'

registry = CloudflareWorkers::AsyncRegistry.new
CloudflareWorkers::AsyncRegistry::Builder.new(registry).instance_eval do
  async_method 'Cloudflare::D1Database', :execute
  async_method 'Cloudflare::D1Database', :execute_insert
  async_method 'Cloudflare::D1Database', :prepare
  taint_return 'Cloudflare::D1Database', :[], 'Sequel::Dataset'
  async_method 'Sequel::Dataset', :insert
  async_method 'Sequel::Dataset', :all
  async_method 'Sequel::Dataset', :first
  taint_return 'Sequel::Dataset', :where, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :order, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :limit, 'Sequel::Dataset'
  async_factory 'Cloudflare::Email', :new
  async_method 'Cloudflare::Email', :send
  taint_return 'Cloudflare::DurableObjectState', :storage, 'Cloudflare::DurableObjectStorage'
  async_method 'Cloudflare::DurableObjectStorage', :get
  async_method 'Cloudflare::DurableObjectStorage', :put
  async_accessor :env, :DB, 'Cloudflare::D1Database'
  async_accessor :env, :SEND_EMAIL, 'Cloudflare::Email'
  helper_factory :send_email, 'Cloudflare::Email'
  async_helper :cache_get, 'Homura::CloudflareBindingHelpers'
  async_method 'JWT', :decode
end

passed = 0
failed = 0

def assert_eq(expected, actual, msg)
  if expected == actual
    true
  else
    puts "  FAIL: #{msg}"
    puts "    expected: #{expected.inspect}"
    puts "    actual:   #{actual.inspect}"
    false
  end
end

def assert_transform(source, expected, registry)
  analyzer = CloudflareWorkers::AutoAwait::Analyzer.new(registry)
  buffer, nodes = analyzer.process(source, '(test)')
  actual = nodes.map { |n| n.loc.expression.source }
  [assert_eq(expected, actual, "transform targets for: #{source[0..50]}"), actual]
end

# Test 1: basic accessor chain
src1 = <<~RUBY
  db = env['cloudflare.env'].DB
  db.execute('SELECT 1')
RUBY
ok, _ = assert_transform(src1, ["db.execute('SELECT 1')"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 2: Sequel chain
src2 = <<~RUBY
  db = env['cloudflare.env'].DB
  db[:users].where(active: true).insert(name: 'foo')
RUBY
ok, _ = assert_transform(src2, ["db[:users].where(active: true).insert(name: 'foo')"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 3: sync methods on tainted receiver should NOT be awaited
src3 = <<~RUBY
  db = env['cloudflare.env'].DB
  ds = db[:users].where(active: true)
  ds.insert(name: 'foo')
RUBY
ok, _ = assert_transform(src3, ["ds.insert(name: 'foo')"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 4: Email factory + async method
src4 = <<~RUBY
  email = Cloudflare::Email.new(env.SEND_EMAIL)
  email.send(to: 'a@b.com', subject: 'hi', text: 'hello')
RUBY
ok, _ = assert_transform(src4, ["email.send(to: 'a@b.com', subject: 'hi', text: 'hello')"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 5: result.to_s should NOT be awaited (tainted but sync method)
src5 = <<~RUBY
  db = env['cloudflare.env'].DB
  result = db[:users].insert(name: 'foo')
  result.to_s
RUBY
ok, _ = assert_transform(src5, ["db[:users].insert(name: 'foo')"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 6: full transform
src6 = <<~RUBY
  post '/users' do
    db = env['cloudflare.env'].DB
    result = db[:users].where(active: true).insert(name: 'foo')
    list   = db[:users].where(active: true).order(:name).limit(10)
    email  = Cloudflare::Email.new(env.SEND_EMAIL)
    email.send(to: 'a@b.com', subject: 'hi', text: 'hello')
    result.to_s
    all_rows = list.all
  end
RUBY
analyzer = CloudflareWorkers::AutoAwait::Analyzer.new(registry)
buffer, nodes = analyzer.process(src6, '(test)')
transformed = CloudflareWorkers::AutoAwait::Transformer.transform(src6, nodes, buffer)

expected_lines = [
  "db[:users].where(active: true).insert(name: 'foo')",
  "email.send(to: 'a@b.com', subject: 'hi', text: 'hello')",
  "all_rows = list.all"
]
expected_lines.each do |line|
  if transformed.include?("#{line}.__await__")
    passed += 1
  else
    puts "  FAIL: expected #{line}.__await__ in transformed source"
    failed += 1
  end
end

# Verify no over-await
if transformed.include?("result.to_s.__await__")
  puts "  FAIL: result.to_s should NOT be awaited"
  failed += 1
else
  passed += 1
end

if transformed.include?("Cloudflare::Email.new(env.SEND_EMAIL).__await__")
  puts "  FAIL: Cloudflare::Email.new should NOT be awaited"
  failed += 1
else
  passed += 1
end

# Test 7: begin/rescue keeps JWT.decode awaitable without manual IIFE
src7 = <<~RUBY
  begin
    JWT.decode(token, verify_key, true, algorithm: algorithm)
  rescue JWT::DecodeError => e
    next [401, { 'error' => e.message }.to_json]
  end
RUBY
ok, _ = assert_transform(src7, ["JWT.decode(token, verify_key, true, algorithm: algorithm)"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 8: helper_factory local var survives opaque helper/controller calls
src8 = <<~RUBY
  mail = send_email
  ctx = Homura::DebugMailController.prepare_send(params, env, self, mail)
  mail.send(to: ctx[:final_to], subject: ctx[:subject_line], text: ctx[:text_body])
RUBY
ok, _ = assert_transform(src8, ["mail.send(to: ctx[:final_to], subject: ctx[:subject_line], text: ctx[:text_body])"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 9: async helper call with explicit block arg is awaited
src9 = <<~RUBY
  compute_body = proc { 'ok' }
  body = cache_get(cache_key, ttl: ttl, &compute_body)
RUBY
ok, _ = assert_transform(src9, ["cache_get(cache_key, ttl: ttl, &compute_body)"], registry)
passed += 1 if ok
failed += 1 unless ok

# Test 10: DurableObject.define block binds state.storage async methods
src10 = <<~RUBY
  Cloudflare::DurableObject.define('Counter') do |state, request|
    prev = (state.storage.get('count') || 0).to_i
    state.storage.put('count', prev + 1)
  end
RUBY
ok, _ = assert_transform(src10, ["state.storage.get('count')", "state.storage.put('count', prev + 1)"], registry)
passed += 1 if ok
failed += 1 unless ok

puts "\n#{passed} passed, #{failed} failed"
exit(failed > 0 ? 1 : 0)
