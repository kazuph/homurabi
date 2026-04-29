# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Durable Objects wrapper smoke tests.
#
# Exercises the full DO wrapper chain under Node without needing
# wrangler or miniflare, by installing tiny JS fakes that stand in
# for the DO runtime:
#
#   1. DurableObjectNamespace#id_from_name / new_unique_id / get
#      forward to the JS binding's idFromName / newUniqueId / get.
#   2. DurableObjectStub#fetch builds a fetch init + awaits the body,
#      returning a Cloudflare::HTTPResponse with the right status
#      and parsed headers.
#   3. DurableObjectStorage#get / put / delete / list serialise Ruby
#      values to JSON and parse on read.
#   4. Cloudflare::DurableObject.define registers a Ruby handler.
#      Calling the dispatcher with a registered class name runs the
#      handler and returns a JS Response wrapping its result.
#   5. The JS dispatcher hook
#      (`globalThis.__HOMURA_DO_DISPATCH__`) is installed on load.
#   6. normalise_response handles Array triple / Hash / plain String.
#
# Usage:
#   npm run test:do
#   npm test                # full suite

require 'json'
require 'homura/runtime'

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
# JS fake factories — defined as globalThis functions so Ruby methods
# can call them through a single-line backtick. (Opal's multi-line
# x-strings containing an IIFE are treated as statements, not
# expressions, so the returned value would be dropped.)
# ---------------------------------------------------------------------

`globalThis.__homura_do_fake_namespace = function() { var ns = { _calls: { idFromName: [], newUniqueId: 0, get: [] }, idFromName: function(name) { ns._calls.idFromName.push(name); var captured = name; return { kind: 'named', name: captured, toString: function() { return 'id::' + captured; } }; }, newUniqueId: function() { ns._calls.newUniqueId += 1; var n = ns._calls.newUniqueId; return { kind: 'unique', n: n, toString: function() { return 'uid::' + n; } }; }, idFromString: function(s) { var captured = s; return { kind: 'parsed', hex: captured, toString: function() { return captured; } }; }, get: function(id) { ns._calls.get.push(id); return { _lastInit: null, fetch: function(url, init) { this._lastInit = { url: url, init: init }; return Promise.resolve(new Response(JSON.stringify({ url: url, method: (init && init.method) || 'GET', id: (id && id.toString && id.toString()) }), { status: 200, headers: { 'content-type': 'application/json', 'x-homura-test': 'yes' } })); } }; } }; return ns; };`

`globalThis.__homura_do_fake_storage = function() { var m = new Map(); return { _map: m, get: function(k) { return Promise.resolve(m.has(k) ? m.get(k) : null); }, put: function(k, v) { m.set(k, v); return Promise.resolve(); }, delete: function(k) { var had = m.has(k); m.delete(k); return Promise.resolve(had); }, deleteAll: function() { m.clear(); return Promise.resolve(); }, list: function(_opts) { var out = new Map(); m.forEach(function(v, k) { out.set(k, v); }); return Promise.resolve(out); } }; };`

def fake_namespace
  `globalThis.__homura_do_fake_namespace()`
end

def fake_storage
  `globalThis.__homura_do_fake_storage()`
end

$stdout.puts '=== homura Phase 11B — DurableObject smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# 1. DurableObjectNamespace
# ---------------------------------------------------------------------
$stdout.puts '--- DurableObjectNamespace ---'

SmokeTest.assert('id_from_name forwards to js.idFromName and returns a DurableObjectId') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  id = ns.id_from_name('global')
  id.is_a?(Cloudflare::DurableObjectId) && id.to_s == 'id::global' &&
    `#{js_ns}._calls.idFromName[0]` == 'global'
end

SmokeTest.assert('new_unique_id forwards to js.newUniqueId and returns a DurableObjectId') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  a = ns.new_unique_id
  b = ns.new_unique_id
  a.is_a?(Cloudflare::DurableObjectId) && b.is_a?(Cloudflare::DurableObjectId) &&
    a.to_s != b.to_s && `#{js_ns}._calls.newUniqueId` == 2
end

SmokeTest.assert('get returns a DurableObjectStub') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  stub = ns.get(ns.id_from_name('x'))
  stub.is_a?(Cloudflare::DurableObjectStub)
end

SmokeTest.assert('get_by_name composes id_from_name + get') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  stub = ns.get_by_name('demo')
  stub.is_a?(Cloudflare::DurableObjectStub) && `#{js_ns}._calls.idFromName[0]` == 'demo'
end

SmokeTest.assert('id_from_string forwards to js.idFromString') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  id = ns.id_from_string('deadbeef')
  id.is_a?(Cloudflare::DurableObjectId) && id.to_s == 'deadbeef'
end

# ---------------------------------------------------------------------
# 2. DurableObjectStub#fetch
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- DurableObjectStub#fetch ---'

SmokeTest.assert('fetch returns Cloudflare::HTTPResponse with status + headers') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  stub = ns.get_by_name('a')
  res = stub.fetch('/peek').__await__
  res.is_a?(Cloudflare::HTTPResponse) && res.status == 200 &&
    res['x-homura-test'] == 'yes' && res['content-type'] == 'application/json'
end

SmokeTest.assert('fetch with method: POST includes POST in the init object') do
  js_ns = fake_namespace
  ns = Cloudflare::DurableObjectNamespace.new(js_ns)
  stub = ns.get_by_name('a')
  res = stub.fetch('/inc', method: 'POST').__await__
  body = JSON.parse(res.body)
  body['method'] == 'POST' && body['url'] == '/inc'
end

SmokeTest.assert('fetch raises DurableObjectError when the JS stub rejects') do
  bad_stub = `({ fetch: function() { return Promise.reject(new Error('do-kaboom')); } })`
  stub = Cloudflare::DurableObjectStub.new(bad_stub)
  raised = false
  begin
    stub.fetch('/x').__await__
  rescue Cloudflare::DurableObjectError => e
    raised = e.message.include?('do-kaboom')
  end
  raised
end

# ---------------------------------------------------------------------
# 3. DurableObjectStorage — JSON round-trip
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- DurableObjectStorage ---'

SmokeTest.assert('put + get round-trips a Ruby Hash through JSON') do
  storage = Cloudflare::DurableObjectStorage.new(fake_storage)
  storage.put('config', { 'a' => 1, 'b' => 'two' }).__await__
  got = storage.get('config').__await__
  got.is_a?(Hash) && got['a'] == 1 && got['b'] == 'two'
end

SmokeTest.assert('put + get round-trips a plain integer') do
  storage = Cloudflare::DurableObjectStorage.new(fake_storage)
  storage.put('count', 42).__await__
  storage.get('count').__await__ == 42
end

SmokeTest.assert('get on missing key returns nil') do
  storage = Cloudflare::DurableObjectStorage.new(fake_storage)
  storage.get('missing').__await__.nil?
end

SmokeTest.assert('delete removes a previously put key') do
  storage = Cloudflare::DurableObjectStorage.new(fake_storage)
  storage.put('k', 'v').__await__
  storage.delete('k').__await__ == true
  storage.get('k').__await__.nil?
end

SmokeTest.assert('delete_all clears every key') do
  js_storage = fake_storage
  storage = Cloudflare::DurableObjectStorage.new(js_storage)
  storage.put('a', 1).__await__
  storage.put('b', 2).__await__
  storage.delete_all.__await__
  `#{js_storage}._map.size` == 0
end

SmokeTest.assert('list returns a Ruby Hash of parsed values') do
  storage = Cloudflare::DurableObjectStorage.new(fake_storage)
  storage.put('u:1', { 'name' => 'alice' }).__await__
  storage.put('u:2', { 'name' => 'bob' }).__await__
  result = storage.list.__await__
  # Copilot review PR #9: list now returns a Ruby Hash directly,
  # not a JS Map — callers no longer need backticks to iterate.
  result.is_a?(Hash) && result['u:1']['name'] == 'alice' && result['u:2']['name'] == 'bob'
end

# ---------------------------------------------------------------------
# 4. Cloudflare::DurableObject.define + dispatcher
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- DurableObject.define + dispatcher ---'

SmokeTest.assert('define registers a handler retrievable via handler_for') do
  Cloudflare::DurableObject.handlers.delete('SmokeClass')
  Cloudflare::DurableObject.define('SmokeClass') { |_state, _req| [200, {}, 'hello'] }
  !Cloudflare::DurableObject.handler_for('SmokeClass').nil?
end

SmokeTest.assert('dispatcher calls the registered handler and returns a JS Response') do
  Cloudflare::DurableObject.handlers.delete('DispatchClass')
  Cloudflare::DurableObject.define('DispatchClass') do |_state, req|
    [200, { 'content-type' => 'application/json' }, { 'path' => req.path }.to_json]
  end
  js_state = `({ id: { toString: function() { return 'abc' } }, storage: #{fake_storage} })`
  js_req = `new Request('https://do/foo/bar', { method: 'GET' })`
  js_resp = Cloudflare::DurableObject.dispatch_js('DispatchClass', js_state, `({})`, js_req, '').__await__
  status = `#{js_resp}.status`
  text = `#{js_resp}.text()`.__await__
  body = JSON.parse(text)
  status == 200 && body['path'] == '/foo/bar'
end

SmokeTest.assert('dispatcher returns 500 JSON Response when no handler is registered') do
  js_state = `({ id: { toString: function() { return '' } }, storage: #{fake_storage} })`
  js_req = `new Request('https://do/whatever')`
  js_resp = Cloudflare::DurableObject.dispatch_js('UnknownClass', js_state, `({})`, js_req, '').__await__
  status = `#{js_resp}.status`
  text = `#{js_resp}.text()`.__await__
  body = JSON.parse(text)
  status == 500 && body['error'].include?('UnknownClass')
end

SmokeTest.assert('handler sees request.body when body_text is passed in') do
  Cloudflare::DurableObject.handlers.delete('BodyClass')
  Cloudflare::DurableObject.define('BodyClass') do |_state, req|
    [200, {}, req.body]
  end
  js_state = `({ id: { toString: function() { return '' } }, storage: #{fake_storage} })`
  js_req = `new Request('https://do/post', { method: 'POST' })`
  js_resp = Cloudflare::DurableObject.dispatch_js('BodyClass', js_state, `({})`, js_req, 'payload-123').__await__
  text = `#{js_resp}.text()`.__await__
  text == 'payload-123'
end

SmokeTest.assert('handler return-value normaliser accepts String as 200 text/plain') do
  Cloudflare::DurableObject.handlers.delete('StringClass')
  Cloudflare::DurableObject.define('StringClass') { |_state, _req| 'just a string' }
  js_state = `({ id: { toString: function() { return '' } }, storage: #{fake_storage} })`
  js_req = `new Request('https://do/s')`
  js_resp = Cloudflare::DurableObject.dispatch_js('StringClass', js_state, `({})`, js_req, '').__await__
  status = `#{js_resp}.status`
  ct = `#{js_resp}.headers.get('content-type')`
  text = `#{js_resp}.text()`.__await__
  status == 200 && text == 'just a string' && ct.include?('text/plain')
end

# ---------------------------------------------------------------------
# 5. Integration — storage round-trip through a registered handler
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Integration: storage through a handler ---'

SmokeTest.assert('counter DO handler increments across two calls on the same storage') do
  Cloudflare::DurableObject.handlers.delete('SmokeCounter')
  Cloudflare::DurableObject.define('SmokeCounter') do |state, _req|
    prev = (state.storage.get('count').__await__ || 0).to_i
    state.storage.put('count', prev + 1).__await__
    [200, { 'content-type' => 'application/json' }, { 'count' => prev + 1 }.to_json]
  end
  shared_storage = fake_storage
  js_state = `({ id: { toString: function() { return 'shared' } }, storage: #{shared_storage} })`
  js_req = `new Request('https://do/inc', { method: 'POST' })`

  js_resp1 = Cloudflare::DurableObject.dispatch_js('SmokeCounter', js_state, `({})`, js_req, '').__await__
  js_resp2 = Cloudflare::DurableObject.dispatch_js('SmokeCounter', js_state, `({})`, js_req, '').__await__
  body1 = JSON.parse(`#{js_resp1}.text()`.__await__)
  body2 = JSON.parse(`#{js_resp2}.text()`.__await__)
  body1['count'] == 1 && body2['count'] == 2
end

# ---------------------------------------------------------------------
# 5b. DurableObjectState — blockConcurrencyWhile
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- DurableObjectState#block_concurrency_while ---'

SmokeTest.assert('block_concurrency_while forwards to state.blockConcurrencyWhile and resolves') do
  # Fake state that records whether blockConcurrencyWhile was called
  # and resolves the supplied async function's promise.
  `globalThis.__homura_do_fake_state_with_bcw = function() { var calls = 0; return { id: { toString: function() { return 'xyz'; } }, blockConcurrencyWhile: function(fn) { calls += 1; return fn(); }, storage: {}, __calls: function() { return calls; } }; };`
  js_state = `globalThis.__homura_do_fake_state_with_bcw()`
  state = Cloudflare::DurableObjectState.new(js_state)
  resolved = state.block_concurrency_while(`Promise.resolve('locked-value')`).__await__
  resolved == 'locked-value' && `#{js_state}.__calls()` == 1
end

SmokeTest.assert('block_concurrency_while falls back to the raw promise when state lacks BCW') do
  # Older DO runtimes (and some tests) don't expose blockConcurrencyWhile;
  # the helper must pass the promise through unchanged rather than raise.
  js_state = `({ id: { toString: function() { return 'nobcw'; } } })`
  state = Cloudflare::DurableObjectState.new(js_state)
  resolved = state.block_concurrency_while(`Promise.resolve(42)`).__await__
  resolved == 42
end

SmokeTest.assert('block_concurrency_while serialises two reads of a shared counter') do
  # Emulate the classic "read + modify + write" race that BCW exists to
  # solve: two async tasks each read the current counter, increment it,
  # and write it back. Without serialisation, both read 0 and both
  # write 1 (the second write clobbers the first). With
  # block_concurrency_while wrapping each read-modify-write, the
  # counter ends at 2.
  #
  # The fake state implements blockConcurrencyWhile with a shared
  # async mutex — identical semantics to the Workers runtime.
  `globalThis.__homura_do_fake_bcw_serialising = function() { var currentMutex = Promise.resolve(); return { id: { toString: function() { return 's'; } }, storage: (function() { var m = 0; return { get: function() { return new Promise(function(r) { setTimeout(function() { r(m); }, 5); }); }, put: function(_k, v) { m = v; return Promise.resolve(); } }; })(), blockConcurrencyWhile: function(fn) { var next = currentMutex.then(function() { return fn(); }); currentMutex = next.catch(function() {}); return next; } }; };`
  js_state = `globalThis.__homura_do_fake_bcw_serialising()`
  state = Cloudflare::DurableObjectState.new(js_state)
  # Schedule two concurrent increments, both protected by BCW.
  p1 = state.block_concurrency_while(`
    (async function(storage) {
      var prev = await storage.get('c');
      await new Promise(function(r) { setTimeout(r, 5); });   // widen the window
      await storage.put('c', prev + 1);
      return prev + 1;
    })(#{`#{js_state}.storage`})
  `)
  p2 = state.block_concurrency_while(`
    (async function(storage) {
      var prev = await storage.get('c');
      await new Promise(function(r) { setTimeout(r, 5); });
      await storage.put('c', prev + 1);
      return prev + 1;
    })(#{`#{js_state}.storage`})
  `)
  final = p1.__await__
  final2 = p2.__await__
  final == 1 && final2 == 2
end

# ---------------------------------------------------------------------
# 6. JS dispatcher hook
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- JS dispatcher hook ---'

SmokeTest.assert('globalThis.__HOMURA_DO_DISPATCH__ is installed') do
  `typeof globalThis.__HOMURA_DO_DISPATCH__ === 'function'`
end

SmokeTest.assert('globalThis.__HOMURA_DO_WS_MESSAGE__ is installed') do
  `typeof globalThis.__HOMURA_DO_WS_MESSAGE__ === 'function'`
end

SmokeTest.assert('globalThis.__HOMURA_DO_WS_CLOSE__ is installed') do
  `typeof globalThis.__HOMURA_DO_WS_CLOSE__ === 'function'`
end

SmokeTest.assert('define_web_socket_handlers registers on_message + on_close handlers') do
  Cloudflare::DurableObject.define_web_socket_handlers('WsSmoke',
    on_message: ->(_ws, _msg, _state) { :msg },
    on_close:   ->(_ws, _c, _r, _clean, _state) { :close }
  )
  h = Cloudflare::DurableObject.web_socket_handlers_for('WsSmoke')
  h[:on_message].respond_to?(:call) && h[:on_close].respond_to?(:call) && h[:on_error].nil?
end

SmokeTest.assert('WS message dispatcher invokes the registered on_message lambda') do
  received = {}
  Cloudflare::DurableObject.define_web_socket_handlers('WsMsgSmoke',
    on_message: ->(ws, msg, state) {
      received[:ws]    = ws
      received[:msg]   = msg
      received[:state] = state
    }
  )
  js_ws = `({ send: function(){} })`
  js_state = `({ id: { toString: function() { return 'ws-id' } }, storage: #{fake_storage} })`
  Cloudflare::DurableObject.dispatch_ws_message('WsMsgSmoke', js_ws, 'hello-inside', js_state, `({})`)
  received[:msg] == 'hello-inside' && received[:state].is_a?(Cloudflare::DurableObjectState) &&
    received[:state].id == 'ws-id'
end

SmokeTest.assert('WS close dispatcher invokes the registered on_close lambda with code + reason') do
  captured = nil
  Cloudflare::DurableObject.define_web_socket_handlers('WsCloseSmoke',
    on_close: ->(_ws, code, reason, clean, _state) {
      captured = { code: code, reason: reason, clean: clean }
    }
  )
  js_ws = `({})`
  js_state = `({ id: { toString: function() { return 'x' } }, storage: #{fake_storage} })`
  Cloudflare::DurableObject.dispatch_ws_close('WsCloseSmoke', js_ws, 1001, 'going away', true, js_state, `({})`)
  captured[:code] == 1001 && captured[:reason] == 'going away' && captured[:clean] == true
end

SmokeTest.assert('WS dispatch for an unregistered class is a no-op, returns nil') do
  # No call to define_web_socket_handlers('WsMissing', …) — the
  # dispatcher must silently return nil rather than raise.
  js_ws = `({})`
  js_state = `({ id: { toString: function() { return 'x' } }, storage: #{fake_storage} })`
  result = Cloudflare::DurableObject.dispatch_ws_message('WsMissing', js_ws, 'anything', js_state, `({})`)
  result.nil?
end

SmokeTest.assert('JS hook forwards through to the Ruby dispatcher') do
  Cloudflare::DurableObject.handlers.delete('JSHook')
  Cloudflare::DurableObject.define('JSHook') { |_state, req| [201, {}, req.method] }
  js_state = `({ id: { toString: function() { return 'x' } }, storage: #{fake_storage} })`
  js_req = `new Request('https://do/h', { method: 'PUT' })`
  promise = `globalThis.__HOMURA_DO_DISPATCH__('JSHook', #{js_state}, ({}), #{js_req}, '')`
  js_resp = promise.__await__
  status = `#{js_resp}.status`
  text = `#{js_resp}.text()`.__await__
  status == 201 && text == 'PUT'
end

success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
