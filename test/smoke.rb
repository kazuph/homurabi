# frozen_string_literal: true
# await: true
#
# homurabi smoke / contract test suite.
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
require 'sinatra/base'

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
  end

  before { @req_id = rand(9999) }

  # --- sync routes ---
  get '/' do
    "home:#{settings.app_name}:#{@req_id > 0}"
  end

  get '/hello/:name' do
    "hello:#{params['name']}"
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

# =====================================================================
# Tests
# =====================================================================

$stdout.puts "=== homurabi smoke tests ==="
$stdout.puts ""

$stdout.puts "--- Route matching ---"
SmokeTest.assert("GET / returns 200") { call_app('GET', '/')[0] == 200 }
SmokeTest.assert("GET / body includes app_name") { call_app('GET', '/')[2].include?('SmokeTestApp') }
SmokeTest.assert("GET /hello/kazu matches :name") { call_app('GET', '/hello/kazu')[2] == 'hello:kazu' }
SmokeTest.assert("GET /nonexistent returns 404") { call_app('GET', '/nonexistent')[0] == 404 }

$stdout.puts ""
$stdout.puts "--- Sinatra features ---"
SmokeTest.assert("before filter sets @req_id") { call_app('GET', '/')[2].include?('true') }
SmokeTest.assert("helpers work") { call_app('GET', '/helper')[2] == 'hi world' }
SmokeTest.assert("redirect returns 302") { call_app('GET', '/redirect')[0] == 302 }
SmokeTest.assert("redirect sets Location") { call_app('GET', '/redirect')[1]['location'].to_s.include?('/dest') }
SmokeTest.assert("halt returns 403") { call_app('GET', '/halt')[0] == 403 }
SmokeTest.assert("halt body is 'forbidden'") { call_app('GET', '/halt')[2] == 'forbidden' }
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
