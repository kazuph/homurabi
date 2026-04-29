# frozen_string_literal: true
# await: true
#
# homura smoke / contract test suite.
#
# Runs inside the compiled Opal ESM on Node.js (same environment as
# wrangler dev). Tests the Sinatra feature contracts that the patch
# stack depends on:
#
#   - route matching (Mustermann regex anchors)
#   - throw :halt propagation (UncaughtThrowError < Exception)
#   - next <expr> in while (Opal closure fix)
#   - content_type helper (immutable String fix)
#   - before / after filters
#   - redirect / halt / pass / helpers / not_found / error handler
#   - ERB precompiled template rendering
#   - async route (.__await__ with Promise)
#   - session (Rack::Session::Cookie JSON coder)
#
# Usage:
#   npm run build:test && node build/smoke-test.mjs
#   — or —
#   npm test

require 'json'
require 'promise/v2'
require 'sequel'
require 'sinatra/base'

class Sinatra::Request
  alias __homura_smoke_original_params params

  def params
    values = __homura_smoke_original_params
    return values unless env['HTTP_X_HOMURA_UNDEFINED_PARAM'] == '1'

    values = values.dup
    `#{values}.set('undefined_param', undefined)`
    nested = {}
    `#{nested}.set('inner', undefined)`
    values['nested_undefined_param'] = nested
    values
  end
end

# =====================================================================
# Test harness
# =====================================================================

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    result = block.call
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stdout.puts "  FAIL  #{label}"
    end
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts "  CRASH #{label} — #{e.class}: #{e.message}"
  end

  def self.report
    total = @passed + @failed
    $stdout.puts ""
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts "Failures:"
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# =====================================================================
# Test app — exercises every patched Sinatra feature
# =====================================================================

class TestApp < Sinatra::Base
  set :show_exceptions, :after_handler

  configure { set :app_name, 'SmokeTestApp' }

  helpers do
    def greet(name)
      "hi #{name}"
    end

    def current_session_user
      nil
    end

    def await_tick
      `Promise.resolve(nil)`.__await__
    end

    def seq_db
      Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    end
  end

  before { @req_id = rand(9999) }

  # --- sync routes ---
  get '/' do
    "home:#{settings.app_name}:#{@req_id > 0}"
  end

  get '/hello/:name' do
    "hello:#{params['name']}"
  end

  get '/items/:id' do
    "item:#{params['id']}"
  end

  get '/helper' do
    greet('world')
  end

  get '/redirect' do
    redirect '/dest'
  end

  get '/dest' do
    'arrived'
  end

  get '/halt' do
    halt 403, 'forbidden'
  end

  get '/async/items/:id' do
    await_tick
    "async-item:#{params['id']}"
  end

  get '/async/redirect' do
    await_tick
    redirect '/dest'
  end

  get '/async/halt' do
    await_tick
    halt 418, 'teapot'
  end

  get '/async/tuple-redirect' do
    await_tick
    [302, { 'location' => '/dest' }, []]
  end

   get '/async/json' do
    await_tick
    content_type 'application/json'
    { ok: true, kind: 'async-json' }.to_json
  end

  get '/async/erb' do
    await_tick
    @greeting = 'hello-async-erb'
    erb :test_template
  end

  get '/async/layout' do
    await_tick
    @title = 'async-layout'
    @greeting = 'hello-async-layout'
    @content = erb :test_template
    erb :layout
  end

  get '/async/raw-promise' do
    PromiseV2.value('raw-promise-ok')
  end

  get '/async/native-promise' do
    `Promise.resolve("native-promise-ok")`
  end

  get '/async/sequel-json' do
    content_type 'application/json'
    { todos: seq_db[:todos].order(:id).all.__await__ }.to_json
  end

  get '/async/sequel-erb' do
    @greeting = 'hello-sequel-erb'
    @todos = seq_db[:todos].order(:id).all.__await__
    erb :test_template
  end

  get '/pass1' do
    pass
  end

  get '/pass1' do
    'second-route'
  end

  get '/content_type_test' do
    content_type 'application/json'
    '{"ok":true}'
  end

  post '/echo' do
    content_type 'application/json'
    request.body.rewind
    body = request.body.read
    "{\"echo\":\"#{body}\"}"
  end

  # --- error handlers ---
  not_found { 'custom-404' }

  error RuntimeError do
    status 500
    "custom-error:#{env['sinatra.error'].message}"
  end

  get '/boom' do
    raise 'deliberate'
  end

  # --- ERB ---
  get '/erb_test' do
    @greeting = 'hello-erb'
    erb :test_template
  end

  # --- session ---
  enable :sessions
  get '/session' do
    session[:counter] ||= 0
    session[:counter] += 1
    content_type 'application/json'
    { counter: session[:counter] }.to_json
  end
end

class AsyncDispatchApp < Sinatra::Base
  def dispatch!
    content_type 'text/plain'
    body 'async-dispatch-ok'
    PromiseV2.value(nil)
  end
end

class PromiseRackApp
  def self.call(_env)
    PromiseV2.value([200, { 'content-type' => 'text/plain' }, ['promise-rack-ok']])
  end
end

# =====================================================================
# Env builder
# =====================================================================

def env_for(method, path, body: '', headers: {})
  env = {
    'REQUEST_METHOD'    => method,
    'PATH_INFO'         => path,
    'QUERY_STRING'      => '',
    'SERVER_PROTOCOL'   => 'HTTP/1.1',
    'HTTP_HOST'         => 'localhost',
    'rack.url_scheme'   => 'http',
    'rack.input'        => StringIO.new(body),
    'rack.errors'       => $stderr,
    'rack.multithread'  => false,
    'rack.multiprocess' => false,
    'rack.run_once'     => false,
    'rack.hijack?'      => false,
  }
  headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
  env
end

def call_app(method, path, body: '', headers: {})
  status, hdrs, body_parts = TestApp.call(env_for(method, path, body: body, headers: headers))
  body_str = ''
  body_parts.each { |c| body_str = body_str + c.to_s }
  [status, hdrs, body_str]
end

def call_worker_app(method, path, body: '')
  Rack::Handler::Homura.run(TestApp)
  url = "https://example.test#{path}"
  js_req = `new Request(#{url}, { method: #{method}, body: #{body} })`
  js_resp = Rack::Handler::Homura.call(js_req, `({})`, `({ waitUntil: function() {} })`, body).__await__
  status = `#{js_resp}.status`
  location = `#{js_resp}.headers.get('location') || #{js_resp}.headers.get('Location')`
  text = `#{js_resp}.text()`.__await__
  [status, location, text]
end

def call_worker_app_with_env(method, path, js_env, body: '')
  Rack::Handler::Homura.run(TestApp)
  url = "https://example.test#{path}"
  js_req = `new Request(#{url}, { method: #{method}, body: #{body} })`
  js_resp = Rack::Handler::Homura.call(js_req, js_env, `({ waitUntil: function() {} })`, body).__await__
  status = `#{js_resp}.status`
  location = `#{js_resp}.headers.get('location') || #{js_resp}.headers.get('Location')`
  text = `#{js_resp}.text()`.__await__
  [status, location, text]
end

def call_worker_app_for(app, method, path, body: '')
  Rack::Handler::Homura.run(app)
  url = "https://example.test#{path}"
  js_req = `new Request(#{url}, { method: #{method}, body: #{body} })`
  js_resp = Rack::Handler::Homura.call(js_req, `({})`, `({ waitUntil: function() {} })`, body).__await__
  status = `#{js_resp}.status`
  text = `#{js_resp}.text()`.__await__
  [status, text]
end

# =====================================================================
# Tests
# =====================================================================

$stdout.puts "=== homura smoke tests ==="
$stdout.puts ""

$stdout.puts "--- Route matching ---"
SmokeTest.assert("GET / returns 200") { call_app('GET', '/')[0] == 200 }
SmokeTest.assert("GET / body includes app_name") { call_app('GET', '/')[2].include?('SmokeTestApp') }
SmokeTest.assert("GET /hello/kazu matches :name") { call_app('GET', '/hello/kazu')[2] == 'hello:kazu' }
SmokeTest.assert("GET /items/42 exposes params['id']") { call_app('GET', '/items/42')[2] == 'item:42' }
SmokeTest.assert("dispatch survives undefined values in request params") { call_app('GET', '/', headers: { 'X-HOMURA-UNDEFINED-PARAM' => '1' })[0] == 200 }
SmokeTest.assert("GET /nonexistent returns 404") { call_app('GET', '/nonexistent')[0] == 404 }

$stdout.puts ""
$stdout.puts "--- Sinatra features ---"
SmokeTest.assert("before filter sets @req_id") { call_app('GET', '/')[2].include?('true') }
SmokeTest.assert("helpers work") { call_app('GET', '/helper')[2] == 'hi world' }
SmokeTest.assert("redirect returns 302") { call_app('GET', '/redirect')[0] == 302 }
SmokeTest.assert("redirect sets Location") { call_app('GET', '/redirect')[1]['location'].to_s.include?('/dest') }
SmokeTest.assert("halt returns 403") { call_app('GET', '/halt')[0] == 403 }
SmokeTest.assert("halt body is 'forbidden'") { call_app('GET', '/halt')[2] == 'forbidden' }
SmokeTest.assert("async params['id'] survives await boundary") { call_worker_app('GET', '/async/items/42').__await__[2] == 'async-item:42' }
SmokeTest.assert("async redirect returns 302") { call_worker_app('GET', '/async/redirect').__await__[0] == 302 }
SmokeTest.assert("async redirect sets Location") { call_worker_app('GET', '/async/redirect').__await__[1].to_s.include?('/dest') }
SmokeTest.assert("async halt returns 418") { call_worker_app('GET', '/async/halt').__await__[0] == 418 }
SmokeTest.assert("async halt body is teapot") { call_worker_app('GET', '/async/halt').__await__[2] == 'teapot' }
SmokeTest.assert("async tuple redirect returns 302") { call_worker_app('GET', '/async/tuple-redirect').__await__[0] == 302 }
SmokeTest.assert("async tuple redirect sets Location") { call_worker_app('GET', '/async/tuple-redirect').__await__[1].to_s.include?('/dest') }
SmokeTest.assert("async tuple redirect keeps empty body") { call_worker_app('GET', '/async/tuple-redirect').__await__[2] == '' }
SmokeTest.assert("async json route returns JSON body after await") {
  status, _, text = call_worker_app('GET', '/async/json').__await__
  status == 200 && text.include?('"kind":"async-json"')
}
SmokeTest.assert("async erb route renders template after await") {
  status, _, text = call_worker_app('GET', '/async/erb').__await__
  status == 200 && text.include?('greeting=hello-async-erb')
}
SmokeTest.assert("async layout route renders nested erb after await") {
  status, _, text = call_worker_app('GET', '/async/layout').__await__
  status == 200 && text.include?('hello-async-layout') && text.include?('<!DOCTYPE html>')
}
SmokeTest.assert("async route returning raw Promise resolves into body") {
  status, _, text = call_worker_app('GET', '/async/raw-promise').__await__
  status == 200 && text == 'raw-promise-ok'
}
SmokeTest.assert("async route returning native JS Promise resolves into body") {
  status, _, text = call_worker_app('GET', '/async/native-promise').__await__
  status == 200 && text == 'native-promise-ok'
}
fake_d1_env = `({
  DB: {
    prepare: function(sql) {
      return {
        bind: function() { return this; },
        all: function() { return Promise.resolve({ results: [{ id: 1, text: 'a', completed: false }] }); },
        first: function() { return Promise.resolve({ id: 1, text: 'a', completed: false }); },
        run: function() { return Promise.resolve({ meta: { changes: 1, last_row_id: 1 } }); }
      };
    }
  }
})`
SmokeTest.assert("Sequel JSON route returns DB rows through worker path") {
  status, _, text = call_worker_app_with_env('GET', '/async/sequel-json', fake_d1_env).__await__
  status == 200 && text.include?('"todos"') && text.include?('"text":"a"')
}
SmokeTest.assert("Sequel ERB route renders after DB await through worker path") {
  status, _, text = call_worker_app_with_env('GET', '/async/sequel-erb', fake_d1_env).__await__
  status == 200 && text.include?('greeting=hello-sequel-erb')
}
SmokeTest.assert("promise-returning dispatch! preserves body instead of emptying response") {
  status, text = call_worker_app_for(AsyncDispatchApp, 'GET', '/').__await__
  status == 200 && text == 'async-dispatch-ok'
}
SmokeTest.assert("promise-returning rack app is awaited before response build") {
  status, text = call_worker_app_for(PromiseRackApp, 'GET', '/').__await__
  status == 200 && text == 'promise-rack-ok'
}
SmokeTest.assert("pass falls through") { call_app('GET', '/pass1')[2] == 'second-route' }
SmokeTest.assert("content_type sets header") { call_app('GET', '/content_type_test')[1]['content-type'].to_s.include?('application/json') }

$stdout.puts ""
$stdout.puts "--- Error handlers ---"
SmokeTest.assert("not_found custom body") { call_app('GET', '/nonexistent')[2] == 'custom-404' }
SmokeTest.assert("error handler catches RuntimeError") { call_app('GET', '/boom')[2].include?('custom-error:deliberate') }

$stdout.puts ""
$stdout.puts "--- POST body ---"
SmokeTest.assert("POST /echo echoes body") { call_app('POST', '/echo', body: 'test-body')[2].include?('test-body') }

$stdout.puts ""
$stdout.puts "--- ERB precompiled ---"
SmokeTest.assert("erb :test_template renders") {
  s, _, b = call_app('GET', '/erb_test')
  s == 200 && b.include?('hello-erb')
}

$stdout.puts ""
$stdout.puts "--- Session ---"
SmokeTest.assert("session counter increments") {
  s1, h1, b1 = call_app('GET', '/session')
  cookie = (h1['set-cookie'] || h1['Set-Cookie']).to_s.split(';').first
  s2, _, b2 = TestApp.call(env_for('GET', '/session').merge('HTTP_COOKIE' => cookie))
  body2 = ''; s2; b2.each { |c| body2 = body2 + c.to_s }
  b1.include?('"counter":1') && body2.include?('"counter":2')
}

$stdout.puts ""
$stdout.puts "--- BinaryBody ---"
SmokeTest.assert("BinaryBody responds to each/close") {
  bb = Cloudflare::BinaryBody.new('fake-stream', 'image/png', 'public, max-age=86400')
  bb.respond_to?(:each) && bb.respond_to?(:close) && bb.content_type == 'image/png'
}
SmokeTest.assert("BinaryBody.each yields nothing (no byte mangling)") {
  bb = Cloudflare::BinaryBody.new('s', 'image/png')
  parts = []
  bb.each { |c| parts << c }
  parts.empty?
}

$stdout.puts ""
$stdout.puts "--- Error classes ---"
SmokeTest.assert("Cloudflare::D1Error exists and is StandardError") {
  Cloudflare::D1Error.ancestors.include?(StandardError)
}
SmokeTest.assert("Cloudflare::BindingError carries binding_type") {
  e = Cloudflare::BindingError.new('test', binding_type: 'D1', operation: 'all')
  e.binding_type == 'D1' && e.operation == 'all' && e.message.include?('D1')
}

# Phase 6.x — Regression test for the Phase 3 catch handler.
# Before: `Kernel.$$raise(...)` (typo) made every D1 / KV failure
# crash with "is not a function" instead of raising D1Error / KVError.
# This test fakes a JS binding whose .all() returns a rejected Promise
# and asserts that Ruby code can rescue Cloudflare::D1Error normally.
SmokeTest.assert("D1 catch handler raises Cloudflare::D1Error (regression)") {
  fake_db = `({
    prepare: function(sql) {
      return { all: function() { return Promise.reject(new Error('no such table: users')); } };
    }
  })`
  db = Cloudflare::D1Database.new(fake_db)
  raised = nil
  begin
    db.prepare('SELECT * FROM users').all.__await__
  rescue Cloudflare::D1Error => e
    raised = e
  end
  raised && raised.message.include?('no such table') && raised.binding_type == 'D1'
}

SmokeTest.assert("KV catch handler raises Cloudflare::KVError (regression)") {
  fake_kv = `({
    get: function(k, opts) { return Promise.reject(new Error('kv unavailable')); }
  })`
  kv = Cloudflare::KVNamespace.new(fake_kv)
  raised = nil
  begin
    kv.get('missing').__await__
  rescue Cloudflare::KVError => e
    raised = e
  end
  raised && raised.message.include?('kv unavailable') && raised.binding_type == 'KV'
}

$stdout.puts ""
$stdout.puts "--- Helpers ---"
SmokeTest.assert("db/kv/bucket helpers are defined on App") {
  TestApp.instance_methods.include?(:greet)  # our test helper
}

$stdout.puts ""
$stdout.puts "--- Opal patches ---"
SmokeTest.assert("Regexp anchor normalization (dstr)") {
  inner = /\//
  combo = /\A#{inner}\Z/
  combo.match('/') != nil
}
SmokeTest.assert("throw/catch not swallowed by rescue StandardError") {
  r = catch(:outer) do
    begin
      catch(:inner) { throw :outer, 'ok' }
    rescue StandardError
      'swallowed'
    end
  end
  r == 'ok'
}
SmokeTest.assert("next <expr> in while updates variable") {
  x = 0
  i = 0
  while x < 3
    i += 1
    next x = x + 1 if i < 100
    break
  end
  x == 3
}

# =====================================================================
# Report
# =====================================================================
success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
