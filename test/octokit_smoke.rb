# frozen_string_literal: true
# await: true
# backtick_javascript: true
#
# octokit-style compatibility smoke for the Faraday shim.
#
# Octokit.rb builds its HTTP client out of Faraday plus a stack of
# middleware: :json, :raise_error, :retry, a custom Authorization
# handler, and a Link-header parser. We don't vendor octokit itself
# (too many transitive deps), but we exercise the exact Faraday call
# sequences octokit uses, so the shim can be swapped in for the real
# gem on Workers without drift.
#
# All HTTP is stubbed via globalThis.fetch replacement — same pattern
# as test/faraday_smoke.rb.

require 'json'
require 'faraday'

module OctokitSmoke
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    r = block.call
    if r
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

# --- fetch stub with URL-aware routing ---------------------------------

`globalThis.__octokit_calls__ = [];`

def install_router(response_factory)
  `
    globalThis.fetch = function(url, init) {
      globalThis.__octokit_calls__.push({ url: url, init: init });
      var r = (typeof #{response_factory} === 'function')
        ? #{response_factory}(url, init)
        : #{response_factory};
      return Promise.resolve(r);
    };
  `
end

def last_call
  `globalThis.__octokit_calls__[globalThis.__octokit_calls__.length - 1]`
end

def all_calls
  `globalThis.__octokit_calls__`
end

def reset_calls
  `globalThis.__octokit_calls__ = []`
  Faraday.reset_default_connection
end

def gh_response(body, status: 200, headers: {})
  merged = { 'content-type' => 'application/json; charset=utf-8' }.merge(headers)
  body_str = body.is_a?(String) ? body : body.to_json
  js_headers = `({})`
  merged.each { |k, v| ks = k.to_s; vs = v.to_s; `#{js_headers}[#{ks}] = #{vs}` }
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

# --- Minimal octokit-style client -------------------------------------
# Builds the exact Faraday stack octokit uses, then exposes #user /
# #repo / #search — the same 3-method surface the real gem hangs off
# `Octokit::Client::Users`, `::Repositories`, `::Search`.

class MiniOctokit
  DEFAULT_USER_AGENT = 'MiniOctokit-test/1.0 (homura-phase11a)'

  attr_reader :conn

  def initialize(token: nil, endpoint: 'https://api.github.com')
    @conn = Faraday.new(url: endpoint, headers: {
      'accept'     => 'application/vnd.github.v3+json',
      'user-agent' => DEFAULT_USER_AGENT
    }) do |c|
      c.request :json
      c.request :authorization, :bearer, token if token
      c.request :retry, max: 2, interval: 0  # short in tests
      c.response :json
      c.response :raise_error
    end
  end

  # In the real (CRuby) octokit gem, these methods return plain Hash /
  # Array right from the wire. On Workers via Opal, every HTTP call is
  # async, so we return the Faraday::Connection Promise and let the
  # caller `.__await__.body` — the same ceremony every other async
  # call site in homura uses. Keep the method body thin so the test
  # exercise matches how octokit would actually lay out the call.
  def user_req(login)
    @conn.get("/users/#{login}")
  end

  def repo_req(nwo)
    @conn.get("/repos/#{nwo}")
  end

  def search_req(q)
    @conn.get('/search/repositories', { 'q' => q })
  end

  def rate_limit_req
    @conn.get('/rate_limit')
  end
end

$stdout.puts "=== octokit-style smoke tests ==="

# 1. User fetch roundtrips; headers carry User-Agent
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'login' => 'kazuph', 'id' => 849165 }) })
OctokitSmoke.assert('GET /users/:login returns parsed JSON body') {
  c = MiniOctokit.new
  u = c.user_req('kazuph').__await__.body
  u['login'] == 'kazuph' && u['id'] == 849165
}
OctokitSmoke.assert('default User-Agent header reaches the wire') {
  `#{last_call}.init.headers['user-agent']`.include?('MiniOctokit')
}

# 2. Token → Authorization: Bearer header
reset_calls
install_router(lambda { |_u, _i| gh_response({}) })
OctokitSmoke.assert('token: option sets Authorization: Bearer ...') {
  c = MiniOctokit.new(token: 'ghp_dummy_token_abc')
  c.user_req('kazuph').__await__ rescue nil
  auth = `#{last_call}.init.headers['authorization']`
  auth == 'Bearer ghp_dummy_token_abc'
}

# 3. Hash bodies encoded as JSON on POST
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'ok' => true }) })
OctokitSmoke.assert('conn.post(path, hash) → application/json body') {
  c = MiniOctokit.new
  c.conn.post('/gists', { 'description' => 'test', 'public' => true }).__await__
  last = last_call
  `#{last}.init.headers['content-type']` == 'application/json' &&
    `#{last}.init.body` == '{"description":"test","public":true}'
}

# 4. 404 raises Faraday::ResourceNotFound, caller can inspect response
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'message' => 'Not Found' }, status: 404) })
OctokitSmoke.assert('404 raises ResourceNotFound with response hash') {
  c = MiniOctokit.new
  raised = nil
  begin
    c.user_req('nonexistent-user-test-11a').__await__
  rescue Faraday::ResourceNotFound => e
    raised = e
  end
  raised && raised.response_status == 404 &&
    raised.response_body.is_a?(Hash) && raised.response_body['message'] == 'Not Found'
}

# 5. 401 raises Faraday::UnauthorizedError
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'message' => 'Bad credentials' }, status: 401) })
OctokitSmoke.assert('401 raises UnauthorizedError') {
  c = MiniOctokit.new(token: 'ghp_fake')
  raised = nil
  begin
    c.user_req('kazuph').__await__
  rescue Faraday::UnauthorizedError => e
    raised = e
  end
  raised && raised.response_status == 401
}

# 6. 403 with rate-limit body raises ForbiddenError; headers accessible
reset_calls
install_router(lambda { |_u, _i|
  gh_response(
    { 'message' => 'API rate limit exceeded' },
    status: 403,
    headers: {
      'x-ratelimit-limit'     => '60',
      'x-ratelimit-remaining' => '0',
      'x-ratelimit-reset'     => '1_800_000_000'
    }
  )
})
OctokitSmoke.assert('403 surface carries rate-limit response headers') {
  c = MiniOctokit.new
  raised = nil
  begin
    c.rate_limit_req.__await__
  rescue Faraday::ForbiddenError => e
    raised = e
  end
  h = raised&.response_headers || {}
  raised && h['x-ratelimit-remaining'] == '0' && h['x-ratelimit-limit'] == '60'
}

# 7. Retry middleware retries 503 (octokit's transient-failure pattern)
reset_calls
`globalThis.__octokit_retry_calls__ = 0`
install_router(lambda { |_u, _i|
  n = `globalThis.__octokit_retry_calls__++`
  if n == 0
    gh_response({}, status: 503)
  else
    gh_response({ 'login' => 'kazuph' })
  end
})
OctokitSmoke.assert('retry middleware retries 503 then returns 200 body') {
  c = MiniOctokit.new
  u = c.user_req('kazuph').__await__.body
  u['login'] == 'kazuph' && `globalThis.__octokit_retry_calls__` == 2
}

# 8. Query params merge (search?q=...)
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'items' => [] }) })
OctokitSmoke.assert('query params encode in URL') {
  c = MiniOctokit.new
  c.search_req('homura in:name').__await__
  url = `#{last_call}.url`
  url.include?('/search/repositories') && url.include?('q=')
}

# 9. Link-header parsing pattern (octokit pagination core)
#    We don't ship a Link-parser, but verify Response#headers preserves it.
reset_calls
link_header = '<https://api.github.com/user/repos?page=2>; rel="next", ' +
              '<https://api.github.com/user/repos?page=10>; rel="last"'
install_router(lambda { |_u, _i|
  gh_response([], headers: { 'link' => link_header })
})
OctokitSmoke.assert('Link header flows through Response#headers') {
  c = MiniOctokit.new
  res = c.conn.get('/user/repos').__await__
  res.headers['link'].include?('rel="next"') &&
    res.headers['link'].include?('rel="last"')
}

# 10. Retry gives up on 500 after max; final response surfaced
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'message' => 'down' }, status: 500) })
OctokitSmoke.assert('retry gives up → 500 surfaces as Faraday::ServerError') {
  c = MiniOctokit.new
  raised = nil
  begin
    c.user_req('kazuph').__await__
  rescue Faraday::ServerError => e
    raised = e
  end
  raised && raised.response_status == 500 && `#{all_calls}.length` == 2  # max: 2
}

# 11. URL prefix joining does not double-slash
reset_calls
install_router(lambda { |_u, _i| gh_response({}) })
OctokitSmoke.assert('URL prefix + "/users/..." path joins cleanly') {
  c = MiniOctokit.new(endpoint: 'https://api.github.com/')   # trailing slash
  c.user_req('kazuph').__await__ rescue nil
  `#{last_call}.url` == 'https://api.github.com/users/kazuph'
}

# 12. Repo-NWO traversal (octokit ubiquitous two-slash pattern)
reset_calls
install_router(lambda { |_u, _i| gh_response({ 'full_name' => 'kazuph/homura' }) })
OctokitSmoke.assert('repo "owner/name" NWO path survives') {
  c = MiniOctokit.new
  r = c.repo_req('kazuph/homura').__await__.body
  r['full_name'] == 'kazuph/homura' &&
    `#{last_call}.url.indexOf('/repos/kazuph/homura')` >= 0
}

success = OctokitSmoke.report
`process.exit(#{success ? 0 : 1})`
