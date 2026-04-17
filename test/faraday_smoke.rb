# frozen_string_literal: true
# await: true
# backtick_javascript: true
#
# Faraday compat-shim smoke tests.
#
# All HTTP is stubbed via a globalThis.fetch replacement so the tests
# run in Node without hitting the network. The pattern matches Phase 6
# http_smoke.rb — replace fetch, record calls, assert request shape +
# response parsing.

require 'json'
require 'faraday'

module FaradaySmoke
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
    @errors.each { |e| $stdout.puts "  - #{e}" } if @errors.any?
    @failed == 0
  end
end

# --- fetch stub --------------------------------------------------------
# Records every call so tests can assert request URL / method / headers.
`globalThis.__homurabi_fetch_calls__ = [];`

def install_stub(response_factory)
  `
    globalThis.fetch = function(url, init) {
      globalThis.__homurabi_fetch_calls__.push({ url: url, init: init });
      var r = (typeof #{response_factory} === 'function')
        ? #{response_factory}(url, init)
        : #{response_factory};
      return Promise.resolve(r);
    };
  `
end

def last_call
  `globalThis.__homurabi_fetch_calls__[globalThis.__homurabi_fetch_calls__.length - 1]`
end

def reset_calls
  `globalThis.__homurabi_fetch_calls__ = []`
  Faraday.reset_default_connection
end

# JS Response stub — mirrors Web Response minimal surface.
def json_response(body, status: 200, headers: { 'content-type' => 'application/json' })
  body_str = body.is_a?(String) ? body : body.to_json
  js_headers = `({})`
  headers.each { |k, v| ks = k.to_s; vs = v.to_s; `#{js_headers}[#{ks}] = #{vs}` }
  `(function() {
    var h = new Headers();
    var keys = Object.keys(#{js_headers});
    for (var i = 0; i < keys.length; i++) { h.set(keys[i], #{js_headers}[keys[i]]); }
    return {
      status: #{status},
      headers: h,
      text: function() { return Promise.resolve(#{body_str}); }
    };
  })()`
end

$stdout.puts "=== Faraday smoke tests ==="

# 1. Top-level Faraday.get with :json default middleware parses JSON body
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'ip' => '1.2.3.4' }) })
FaradaySmoke.assert('Faraday.get parses JSON response via default :json middleware') {
  res = Faraday.get('https://api.ipify.org/').__await__
  res.status == 200 && res.body.is_a?(Hash) && res.body['ip'] == '1.2.3.4'
}

# 2. Connection url_prefix + path joining
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'ok' => true }) })
FaradaySmoke.assert('Connection joins url_prefix + relative path') {
  c = Faraday.new(url: 'https://api.example.com/v1') { |x| x.response :json }
  c.get('/users').__await__
  `#{last_call}.url === 'https://api.example.com/v1/users'`
}

# 3. :json request middleware encodes a Hash body + sets content-type
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'ok' => true }) })
FaradaySmoke.assert('request :json encodes Hash body as JSON') {
  c = Faraday.new(url: 'https://api.example.com') do |x|
    x.request :json
    x.response :json
  end
  c.post('/users', { 'name' => 'kazu' }).__await__
  call = last_call
  body_sent = `#{call}.init.body`
  ct_sent = `#{call}.init.headers['content-type']`
  body_sent == '{"name":"kazu"}' && ct_sent == 'application/json'
}

# 4. :raise_error middleware maps 404 to Faraday::ResourceNotFound
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'error' => 'nope' }, status: 404) })
FaradaySmoke.assert('response :raise_error raises ResourceNotFound on 404') {
  c = Faraday.new(url: 'https://api.example.com') { |x| x.response :raise_error }
  raised = nil
  begin
    c.get('/missing').__await__
  rescue Faraday::ResourceNotFound => e
    raised = e
  end
  raised && raised.response_status == 404
}

# 5. :raise_error middleware maps 500 to Faraday::ServerError
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'boom' => true }, status: 500) })
FaradaySmoke.assert('response :raise_error raises ServerError on 500') {
  c = Faraday.new(url: 'https://api.example.com') { |x| x.response :raise_error }
  raised = nil
  begin
    c.get('/fail').__await__
  rescue Faraday::ServerError => e
    raised = e
  end
  raised && raised.response_status == 500
}

# 6. Block-form request: `conn.post(path) { |req| req.body = ... }`
reset_calls
install_stub(lambda { |_u, _i| json_response({ 'ok' => true }) })
FaradaySmoke.assert('block form sets body / headers on the Request') {
  c = Faraday.new(url: 'https://api.example.com') do |x|
    x.request :json
    x.response :json
  end
  c.post('/widgets') do |req|
    req.body = { 'x' => 1 }
    req.headers['x-custom'] = 'yay'
  end.__await__
  call = last_call
  hx = `#{call}.init.headers['x-custom']`
  bs = `#{call}.init.body`
  hx == 'yay' && bs == '{"x":1}'
}

# 7. Query params merge (connection params + per-request params)
reset_calls
install_stub(lambda { |_u, _i| json_response({}) })
FaradaySmoke.assert('query params: connection + per-request merged into URL') {
  c = Faraday.new(url: 'https://api.example.com', params: { 'api_key' => 'abc' }) do |x|
    x.response :json
  end
  c.get('/search', { 'q' => 'kazuph' }).__await__
  url = `#{last_call}.url`
  url.include?('api_key=abc') && url.include?('q=kazuph')
}

# 8. Authorization middleware builds a Bearer header
reset_calls
install_stub(lambda { |_u, _i| json_response({}) })
FaradaySmoke.assert('request :authorization, :bearer sets Authorization: Bearer ...') {
  c = Faraday.new(url: 'https://api.example.com') do |x|
    x.request :authorization, :bearer, 'deadbeef'
  end
  c.get('/').__await__
  auth = `#{last_call}.init.headers['authorization']`
  auth == 'Bearer deadbeef'
}

# 9. Utils.build_query for nested params
FaradaySmoke.assert('Utils.build_query encodes nested Hash with a[b]=') {
  q = Faraday::Utils.build_query({ 'a' => { 'b' => 1 }, 'list' => [1, 2] })
  q.include?('a%5Bb%5D=1') && q.include?('list%5B%5D=1') && q.include?('list%5B%5D=2')
}

# 10. Absolute URL on .get overrides url_prefix
reset_calls
install_stub(lambda { |_u, _i| json_response({}) })
FaradaySmoke.assert('absolute URL on .get overrides url_prefix') {
  c = Faraday.new(url: 'https://api.example.com')
  c.get('https://other.test/elsewhere').__await__
  `#{last_call}.url.indexOf('https://other.test') === 0`
}

# 11. Response#success? across 2xx / 3xx / 4xx / 5xx
reset_calls
install_stub(lambda { |_u, _i| json_response({}, status: 204) })
FaradaySmoke.assert('Response#success? true for 204') {
  c = Faraday.new(url: 'https://api.example.com')
  c.get('/').__await__.success?
}

reset_calls
install_stub(lambda { |_u, _i| json_response({}, status: 301) })
FaradaySmoke.assert('Response#success? false for 301') {
  c = Faraday.new(url: 'https://api.example.com')
  c.get('/').__await__.success? == false
}

# 12. Response headers accessible via [] (case-insensitive)
reset_calls
install_stub(lambda { |_u, _i|
  json_response({}, headers: { 'content-type' => 'application/json', 'x-rate-limit' => '100' })
})
FaradaySmoke.assert('Response#[] is case-insensitive') {
  c = Faraday.new(url: 'https://api.example.com')
  res = c.get('/').__await__
  res['X-Rate-Limit'] == '100' && res['x-rate-limit'] == '100'
}

# 13. Retry middleware retries 5xx and eventually returns the success
reset_calls
# Stub returns 503 twice, then 200.
`globalThis.__faraday_retry_calls__ = 0`
install_stub(lambda { |_u, _i|
  n = `globalThis.__faraday_retry_calls__++`
  if n < 2
    json_response({ 'try' => n }, status: 503)
  else
    json_response({ 'ok' => true })
  end
})
FaradaySmoke.assert('retry middleware retries 503 and returns success') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 5, interval: 0
    conn.response :json
  end
  res = c.get('/').__await__
  res.status == 200 && res.body['ok'] == true && `globalThis.__faraday_retry_calls__` == 3
}

# 14. Retry gives up after max attempts and returns last response
reset_calls
`globalThis.__faraday_retry_calls__ = 0`
install_stub(lambda { |_u, _i|
  `globalThis.__faraday_retry_calls__++`
  json_response({}, status: 500)
})
FaradaySmoke.assert('retry middleware gives up after `max` attempts') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 3, interval: 0
  end
  res = c.get('/').__await__
  res.status == 500 && `globalThis.__faraday_retry_calls__` == 3
}

# 15. Retry is NOT triggered for non-idempotent methods by default (POST)
reset_calls
`globalThis.__faraday_retry_calls__ = 0`
install_stub(lambda { |_u, _i|
  `globalThis.__faraday_retry_calls__++`
  json_response({}, status: 500)
})
FaradaySmoke.assert('retry middleware does NOT retry POST by default') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 3, interval: 0
  end
  res = c.post('/', 'body').__await__
  # POST is not in DEFAULT_METHODS, so 500 returns on the first hit.
  res.status == 500 && `globalThis.__faraday_retry_calls__` == 1
}

# 16. Retry-After header honored (integer seconds)
reset_calls
`globalThis.__faraday_retry_calls__ = 0`
`globalThis.__faraday_last_call_ts__ = 0`
install_stub(lambda { |_u, _i|
  n = `globalThis.__faraday_retry_calls__++`
  if n == 0
    `globalThis.__faraday_last_call_ts__ = Date.now()`
    json_response({}, status: 429, headers: { 'retry-after' => '1', 'content-type' => 'application/json' })
  else
    json_response({ 'ok' => true })
  end
})
FaradaySmoke.assert('Retry-After header is honored') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 2, interval: 0  # interval 0, so only Retry-After matters
    conn.response :json
  end
  start_ms = `Date.now()`
  res = c.get('/').__await__
  elapsed_ms = `Date.now() - #{start_ms}`
  # Should have slept ~1000ms thanks to Retry-After, allow wide margin.
  res.status == 200 && elapsed_ms >= 900 && `globalThis.__faraday_retry_calls__` == 2
}

# 17. `retry_statuses:` configurable
reset_calls
`globalThis.__faraday_retry_calls__ = 0`
install_stub(lambda { |_u, _i|
  n = `globalThis.__faraday_retry_calls__++`
  json_response({}, status: n == 0 ? 418 : 200)
})
FaradaySmoke.assert('retry_statuses: custom codes') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 3, interval: 0, retry_statuses: [418]
    conn.response :json
  end
  res = c.get('/').__await__
  res.status == 200 && `globalThis.__faraday_retry_calls__` == 2
}

# 18. `methods:` configurable (retry POST too)
reset_calls
`globalThis.__faraday_retry_calls__ = 0`
install_stub(lambda { |_u, _i|
  n = `globalThis.__faraday_retry_calls__++`
  json_response({}, status: n == 0 ? 503 : 201)
})
FaradaySmoke.assert('methods: allows POST retry when opted in') {
  c = Faraday.new(url: 'https://api.example.com') do |conn|
    conn.request :retry, max: 3, interval: 0, methods: [:post]
  end
  res = c.post('/', 'body').__await__
  res.status == 201 && `globalThis.__faraday_retry_calls__` == 2
}

success = FaradaySmoke.report
`process.exit(#{success ? 0 : 1})`
