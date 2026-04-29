# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 6 — HTTP client foundation smoke tests.
#
# Verifies:
#   - Cloudflare::HTTP.fetch wraps globalThis.fetch and returns
#     a Cloudflare::HTTPResponse (status / headers / body / json).
#   - Cloudflare::HTTP.fetch supports POST with body + headers.
#   - Net::HTTP.get(URI) returns body string.
#   - Net::HTTP.get_response returns Net::HTTPResponse with code/body/[].
#   - Net::HTTP.post_form posts urlencoded form data.
#   - URI('https://...') / URI.parse('https://...') exposes host/scheme/path.
#
# Usage:
#   npm run build:http-test && node build/http-smoke.mjs
#   — or —
#   npm run test:http
#
# Tests stub globalThis.fetch so they are deterministic and offline.

require 'json'
require 'homura/runtime/http'
require 'net/http'

# =====================================================================
# Stub globalThis.fetch with a deterministic mock that records the
# last call and returns canned responses based on the URL path.
# =====================================================================

`
globalThis.__last_fetch_call__ = null;
globalThis.fetch = async function(url, init) {
  init = init || {};
  globalThis.__last_fetch_call__ = {
    url: String(url),
    method: init.method || 'GET',
    headers: init.headers || {},
    body: init.body == null ? null : String(init.body)
  };
  var u = new URL(String(url));
  var path = u.pathname;
  var status = 200;
  var headers = new Headers({ 'content-type': 'text/plain', 'x-stub': 'on' });
  var body = 'hello from stub';

  if (path === '/json') {
    headers = new Headers({ 'content-type': 'application/json' });
    body = JSON.stringify({ ok: true, n: 42 });
  } else if (path === '/echo') {
    headers = new Headers({ 'content-type': 'text/plain' });
    body = (init.method || 'GET') + ':' + (init.body || '');
  } else if (path === '/notfound') {
    status = 404;
    body = 'gone';
  } else if (path === '/headers') {
    headers = new Headers({ 'content-type': 'text/plain', 'x-custom': 'received:' + (init.headers && init.headers['x-marker'] || '') });
    body = 'ok';
  } else if (path === '/form') {
    headers = new Headers({ 'content-type': 'text/plain' });
    body = 'form:' + (init.body || '');
  }

  return new Response(body, { status: status, headers: headers });
};
`

# =====================================================================
# Test harness (mirrors test/smoke.rb)
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
# Tests
# =====================================================================

$stdout.puts "=== homura Phase 6 — HTTP smoke ==="
$stdout.puts ""

$stdout.puts "--- Cloudflare::HTTP.fetch ---"

SmokeTest.assert("GET returns Cloudflare::HTTPResponse with status 200") {
  res = Cloudflare::HTTP.fetch('https://example.test/').__await__
  res.is_a?(Cloudflare::HTTPResponse) && res.status == 200
}

SmokeTest.assert("response.body returns String") {
  res = Cloudflare::HTTP.fetch('https://example.test/').__await__
  res.body == 'hello from stub'
}

SmokeTest.assert("response.headers is a Hash with lowercased keys") {
  res = Cloudflare::HTTP.fetch('https://example.test/').__await__
  res.headers['content-type'].to_s.include?('text/plain') &&
    res.headers['x-stub'] == 'on'
}

SmokeTest.assert("response.json parses application/json body") {
  res = Cloudflare::HTTP.fetch('https://example.test/json').__await__
  parsed = res.json
  parsed['ok'] == true && parsed['n'] == 42
}

SmokeTest.assert("404 response has status 404 and body 'gone'") {
  res = Cloudflare::HTTP.fetch('https://example.test/notfound').__await__
  res.status == 404 && res.body == 'gone' && !res.ok?
}

SmokeTest.assert("ok? is true for 2xx, false otherwise") {
  ok  = Cloudflare::HTTP.fetch('https://example.test/').__await__.ok?
  bad = Cloudflare::HTTP.fetch('https://example.test/notfound').__await__.ok?
  ok == true && bad == false
}

SmokeTest.assert("POST with body sends the body to the server") {
  res = Cloudflare::HTTP.fetch('https://example.test/echo',
                               method: 'POST', body: 'hi-there').__await__
  res.body == 'POST:hi-there'
}

SmokeTest.assert("POST forwards custom headers") {
  res = Cloudflare::HTTP.fetch('https://example.test/headers',
                               method: 'POST',
                               headers: { 'x-marker' => 'm1' }).__await__
  res.headers['x-custom'].to_s.include?('received:m1')
}

$stdout.puts ""
$stdout.puts "--- Net::HTTP shim ---"

# Note on # await: true semantics — Opal compiles every method body in
# this file as async, so any helper that itself awaits a Promise still
# returns a Promise. Sinatra routes (and these tests) need an explicit
# `.__await__` on the call site, exactly like the D1/KV/R2 wrappers.
SmokeTest.assert("Net::HTTP.get(URI) returns body String") {
  body = Net::HTTP.get(URI('https://example.test/')).__await__
  body == 'hello from stub'
}

SmokeTest.assert("Net::HTTP.get(URI) accepts an HTTP URL") {
  body = Net::HTTP.get(URI('http://example.test/')).__await__
  body == 'hello from stub'
}

SmokeTest.assert("Net::HTTP.get_response returns Net::HTTPResponse with code/body") {
  res = Net::HTTP.get_response(URI('https://example.test/json')).__await__
  res.is_a?(Net::HTTPResponse) && res.code == '200' && res.body.include?('"ok":true')
}

SmokeTest.assert("Net::HTTPResponse#[] reads a header (case insensitive)") {
  res = Net::HTTP.get_response(URI('https://example.test/json')).__await__
  res['content-type'].to_s.include?('application/json') &&
    res['Content-Type'].to_s.include?('application/json')
}

SmokeTest.assert("Net::HTTP.post_form sends urlencoded body") {
  res = Net::HTTP.post_form(URI('https://example.test/form'),
                            'name' => 'kazu', 'lang' => 'ja').__await__
  # body comes back as 'form:<urlencoded>'; both keys must appear
  b = res.body
  b.start_with?('form:') && b.include?('name=kazu') && b.include?('lang=ja')
}

$stdout.puts ""
$stdout.puts "--- URI sanity (Phase 6 prerequisites) ---"

SmokeTest.assert("URI.parse('https://x.test/p?q=1#f') exposes scheme/host/path/query/fragment") {
  u = URI.parse('https://x.test/p?q=1#f')
  u.scheme == 'https' && u.host == 'x.test' && u.path == '/p' && u.query == 'q=1' && u.fragment == 'f'
}

# =====================================================================
# Report
# =====================================================================
success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
