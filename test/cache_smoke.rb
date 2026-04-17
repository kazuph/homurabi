# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Cache API wrapper smoke tests.
#
# Runs under Node without a live Cloudflare runtime by installing a
# tiny in-memory fake for `caches.default`. The fake implements just
# enough of the Web Cache API surface (match / put / delete) to cover
# every code path in `lib/cloudflare_workers/cache.rb`.
#
#   1. Cache.default wraps the global `caches.default`.
#   2. match returns nil for unknown keys, and a Cloudflare::HTTPResponse
#      for keys previously put.
#   3. put + match preserves body, status, and headers.
#   4. delete removes an entry and returns a boolean.
#   5. The wrapper stays safe when caches is absent (put/delete noop).

require 'json'
require 'cloudflare_workers'

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
    $stdout.puts ''
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts 'Failures:'
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# ---------------------------------------------------------------------
# JS fake: install globalThis.caches with a minimal Cache that stores
# (url => Response) in a Map. Close enough to Workers behaviour for
# the semantics we exercise.
# ---------------------------------------------------------------------

`(function() {
  if (globalThis.__HOMURABI_CACHE_FAKE_INSTALLED__) return;
  var store = new Map();
  function keyFor(req) {
    if (typeof req === 'string') return req;
    if (req && typeof req.url === 'string') return req.url;
    return String(req);
  }
  var fake = {
    match: function(req) {
      var k = keyFor(req);
      if (!store.has(k)) return Promise.resolve(undefined);
      var clone = store.get(k).clone();
      return Promise.resolve(clone);
    },
    put: function(req, resp) {
      var k = keyFor(req);
      // Cache API requires a Response that is NOT a redirect / streaming;
      // we accept it as-is and clone for storage.
      store.set(k, resp.clone());
      return Promise.resolve();
    },
    delete: function(req) {
      var k = keyFor(req);
      var had = store.has(k);
      store.delete(k);
      return Promise.resolve(!!had);
    }
  };
  globalThis.caches = globalThis.caches || {};
  globalThis.caches.default = fake;
  globalThis.caches.open = function(name) { return Promise.resolve(fake); };
  globalThis.__HOMURABI_CACHE_FAKE_INSTALLED__ = true;
  globalThis.__HOMURABI_CACHE_FAKE_STORE__ = store;
})()`

$stdout.puts '=== homurabi Phase 11B — Cache API smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# 1. Cache.default / available?
# ---------------------------------------------------------------------
$stdout.puts '--- Cache.default ---'

SmokeTest.assert('Cache.default returns a Cloudflare::Cache wrapping caches.default') do
  c = Cloudflare::Cache.default
  c.is_a?(Cloudflare::Cache) && c.available?
end

SmokeTest.assert('Cache.open("named") resolves to a wrapped Cloudflare::Cache') do
  # Cache.open is async (it awaits caches.open internally); callers in
  # `# await: true` files must `__await__` the return value before
  # touching the resolved wrapper.
  c = Cloudflare::Cache.open('frag').__await__
  c.is_a?(Cloudflare::Cache) && c.name == 'frag' && c.available?
end

SmokeTest.assert('Cache with nil js is !available?') do
  c = Cloudflare::Cache.new(nil, 'nil-test')
  c.available? == false
end

# ---------------------------------------------------------------------
# 2. match / put round-trip
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- put + match ---'

SmokeTest.assert('match returns nil for a never-stored URL') do
  c = Cloudflare::Cache.default
  c.match('https://example.com/never-stored').__await__.nil?
end

SmokeTest.assert('put + match round-trips body, status, and content-type') do
  c = Cloudflare::Cache.default
  url = 'https://example.com/round-trip'
  c.put(url, '{"hi":1}', status: 200,
    headers: { 'content-type' => 'application/json', 'cache-control' => 'public, max-age=30' }).__await__
  got = c.match(url).__await__
  got.is_a?(Cloudflare::HTTPResponse) && got.status == 200 &&
    got.body == '{"hi":1}' && got['content-type'] == 'application/json'
end

SmokeTest.assert('different URLs produce independent cache entries') do
  c = Cloudflare::Cache.default
  c.put('https://example.com/a', 'AAA', headers: { 'content-type' => 'text/plain' }).__await__
  c.put('https://example.com/b', 'BBB', headers: { 'content-type' => 'text/plain' }).__await__
  c.match('https://example.com/a').__await__.body == 'AAA' &&
    c.match('https://example.com/b').__await__.body == 'BBB'
end

SmokeTest.assert('second match on the same URL returns the SAME body (idempotent cache hit)') do
  c = Cloudflare::Cache.default
  url = 'https://example.com/idempotent'
  c.put(url, 'once', headers: { 'content-type' => 'text/plain' }).__await__
  a = c.match(url).__await__.body
  b = c.match(url).__await__.body
  a == 'once' && b == 'once'
end

# ---------------------------------------------------------------------
# 3. delete
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- delete ---'

SmokeTest.assert('delete removes a stored entry and returns true') do
  c = Cloudflare::Cache.default
  url = 'https://example.com/to-delete'
  c.put(url, 'x', headers: { 'content-type' => 'text/plain' }).__await__
  deleted = c.delete(url).__await__
  absent = c.match(url).__await__
  deleted == true && absent.nil?
end

SmokeTest.assert('delete on a missing key returns false without raising') do
  c = Cloudflare::Cache.default
  c.delete('https://example.com/not-there').__await__ == false
end

# ---------------------------------------------------------------------
# 4. no-caches safety — put on a nil-js Cache is a noop
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- no-caches safety ---'

SmokeTest.assert('put on a Cache with nil js does not raise and returns nil') do
  c = Cloudflare::Cache.new(nil, 'nil-test')
  raised = false
  begin
    c.put('https://example.com/nil', 'x', headers: { 'content-type' => 'text/plain' }).__await__
  rescue ::Exception
    raised = true
  end
  !raised
end

SmokeTest.assert('match on a Cache with nil js returns nil without raising') do
  c = Cloudflare::Cache.new(nil, 'nil-test')
  raised = false
  v = nil
  begin
    v = c.match('https://example.com/nil').__await__
  rescue ::Exception
    raised = true
  end
  !raised && v.nil?
end

SmokeTest.assert('delete on a Cache with nil js returns false') do
  c = Cloudflare::Cache.new(nil, 'nil-test')
  c.delete('https://example.com/nil').__await__ == false
end

# ---------------------------------------------------------------------
# 5. Error propagation
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- error propagation ---'

SmokeTest.assert('put error from the underlying cache is raised as CacheError') do
  bad_cache = `({
    put: function() { return Promise.reject(new Error('cache-kaboom')); },
    match: function() { return Promise.resolve(undefined); },
    delete: function() { return Promise.resolve(false); }
  })`
  c = Cloudflare::Cache.new(bad_cache, 'bad')
  raised = false
  begin
    c.put('https://example.com/bad', 'x', headers: { 'content-type' => 'text/plain' }).__await__
  rescue Cloudflare::CacheError => e
    raised = e.message.include?('cache-kaboom')
  end
  raised
end

SmokeTest.assert('match error from the underlying cache is raised as CacheError') do
  bad_cache = `({
    match: function() { return Promise.reject(new Error('match-kaboom')); },
    put: function() { return Promise.resolve(); },
    delete: function() { return Promise.resolve(false); }
  })`
  c = Cloudflare::Cache.new(bad_cache, 'bad')
  raised = false
  begin
    c.match('https://example.com/bad').__await__
  rescue Cloudflare::CacheError => e
    raised = e.message.include?('match-kaboom')
  end
  raised
end

# ---------------------------------------------------------------------
# 6. request_to_js input accepts the documented shapes
#    (Copilot review PR #9, second pass)
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- request key normalisation ---'

SmokeTest.assert('put accepts a Cloudflare::HTTPResponse as the cache key') do
  c = Cloudflare::Cache.default
  url = 'https://example.com/from-httpresponse'
  src = Cloudflare::HTTPResponse.new(status: 200, headers: { 'x-src' => 'upstream' },
    body: 'forget-me', url: url)
  # Use the HTTPResponse as the key — the wrapper should extract its
  # `.url` and build the corresponding Request under the hood.
  c.put(src, 'stored-through-httpresponse',
    headers: { 'content-type' => 'text/plain' }).__await__
  got = c.match(url).__await__
  got && got.body == 'stored-through-httpresponse'
end

SmokeTest.assert('put rejects an unsupported input type with ArgumentError') do
  c = Cloudflare::Cache.default
  raised = false
  begin
    c.put(12345, 'x', headers: { 'content-type' => 'text/plain' }).__await__
  rescue ArgumentError => e
    raised = e.message.include?('String URL')
  end
  raised
end

success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
