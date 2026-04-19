# frozen_string_literal: true
# await: all, decode, encode, execute, fetch, first, get_first_row, list, match, open, put, run, send, sign, verify
#
# Phase 12.5 — auto-await smoke tests.
#
# Validates that Opal's `# await: <method list>` magic comment correctly
# compiles `.method(...)` calls as `(await method(...))` for listed method
# names, so user code can drop the explicit `.__await__` suffix.
#
# The tests here emulate the Sinatra-route patterns from `app/hello.rb`
# using tiny mock objects that return PromiseV2 instances. If auto-await
# fires correctly, the calling code sees the resolved value directly; if
# not, the caller gets a raw Promise and the assertions fail.
#
# This file uses an explicit sub-list of the app/hello.rb auto-await
# surface — it MUST include `first` because we want to exercise single-
# row Sequel-like access without `.__await__` (the app-level magic
# comment excludes `first` to avoid colliding with Opal's multi-assign
# destructuring; here we test it in isolation).

require 'json'
require 'promise/v2'

# ---------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------

$passed = 0
$failed = 0

def ok(label, cond, note = nil)
  if cond
    $passed += 1
    puts "  PASS  #{label}"
  else
    $failed += 1
    puts "  FAIL  #{label}#{note ? " — #{note}" : ''}"
  end
end

def section(title)
  puts
  puts "--- #{title} ---"
end

# ---------------------------------------------------------------------
# Mock bindings — each returns a PromiseV2 that resolves to a sentinel
# value. With auto-await active, the test body observes the resolved
# value directly; without it, the test body would see a PromiseV2
# object and the `is_a?` assertions would fail.
# ---------------------------------------------------------------------

class MockD1
  def execute(sql)
    PromiseV2.value([{ 'id' => 1, 'name' => 'kazu' }, { 'id' => 2, 'name' => 'homurabi' }])
  end

  def get_first_row(sql, binds)
    PromiseV2.value({ 'id' => binds.first, 'name' => 'found' })
  end
end

class MockKV
  def initialize
    @store = {}
  end

  # auto-await: `put` not in list (collides with Sinatra DSL) — the
  # smoke test asserts that manual `.__await__` on PromiseV2 still
  # works in await-mode magic-comment files.
  def put(key, value)
    @store[key] = value
    PromiseV2.value(true)
  end

  def fetch(key)
    PromiseV2.value(@store[key])
  end
end

class MockJWT
  def self.encode(payload, key, alg)
    PromiseV2.value("#{alg}.#{payload.to_json}.#{key}")
  end

  def self.decode(token, key, verify, opts)
    parts = token.split('.', 3)
    alg = parts[0]
    payload = parts[1] ? JSON.parse(parts[1]) : {}
    PromiseV2.value([payload, { 'alg' => alg }])
  end
end

class MockHTTP
  def self.fetch(url)
    PromiseV2.value({ 'url' => url, 'status' => 200 })
  end
end

class MockAI
  def self.run(model, inputs)
    PromiseV2.value({ 'model' => model, 'reply' => 'hello' })
  end
end

class MockDataset
  def initialize(rows)
    @rows = rows
  end

  def all
    PromiseV2.value(@rows)
  end

  def first
    PromiseV2.value(@rows.first)
  end
end

# Sentinel Proc — auto-await list includes `run` and `send`; this
# exercises block-returning calls across the async boundary.
run_it = proc { |label, value|
  PromiseV2.value({ 'label' => label, 'value' => value })
}

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

section 'D1 execute / get_first_row auto-await'
db = MockD1.new
rows = db.execute('SELECT id, name FROM users')
ok 'db.execute returns Array (auto-awaited PromiseV2)', rows.is_a?(Array)
ok '  — first row is Hash with expected id', rows.first['id'] == 1
row = db.get_first_row('SELECT ...', [42])
ok 'db.get_first_row returns Hash (auto-awaited)', row.is_a?(Hash) && row['id'] == 42

section 'Sequel-like Dataset#all auto-await'
ds = MockDataset.new([{ 'id' => 10, 'n' => 'a' }, { 'id' => 20, 'n' => 'b' }])
arr = ds.all
ok 'ds.all returns Array (auto-awaited)', arr.is_a?(Array) && arr.size == 2
ok '  — second row id is 20', arr[1]['id'] == 20

section 'Sequel-like Dataset#first auto-await (PromiseV2)'
one = ds.first
ok 'ds.first returns Hash (auto-awaited)', one.is_a?(Hash) && one['id'] == 10

section 'JWT encode / decode auto-await'
tok = MockJWT.encode({ 'sub' => 'demo' }, 'sekrit', 'HS256')
ok 'JWT.encode returns String (auto-awaited)', tok.is_a?(String) && tok.start_with?('HS256.')
payload, header = MockJWT.decode(tok, 'sekrit', true, {}).__await__ # multi-assign still needs explicit await
ok 'JWT.decode payload has sub', payload['sub'] == 'demo'
ok 'JWT.decode header has alg', header['alg'] == 'HS256'

section 'HTTP fetch auto-await'
res = MockHTTP.fetch('https://example.invalid/ping')
ok 'HTTP.fetch returns Hash (auto-awaited)', res.is_a?(Hash) && res['status'] == 200

section 'Workers AI run auto-await'
ai = MockAI.run('@cf/demo', { messages: [] })
ok 'AI.run returns Hash (auto-awaited)', ai.is_a?(Hash) && ai['reply'] == 'hello'

section 'KV put with explicit __await__ (control: Sinatra DSL conflict)'
kv = MockKV.new
kv.put('k1', 'v1').__await__
ok 'kv.fetch returns stored value (put manually awaited)', kv.fetch('k1') == 'v1'

section 'Proc#send (auto-await) — carrier for run.call style helpers'
# `send` is in our auto-await list. For the mock, `.send` is defined as
# the Queue DSL entry; calling it returns the label+value hash.
class QueueWrapper
  def send(body)
    PromiseV2.value({ 'enqueued' => body })
  end
end
q = QueueWrapper.new
ack = q.send({ 'hello' => 'queue' })
ok 'queue.send auto-awaits to Hash', ack.is_a?(Hash) && ack['enqueued']['hello'] == 'queue'

section 'Chained method: bucket.list.first (only first wants await)'
# Demonstrates that a chain `list.first` — where `list` returns a
# Promise — needs an explicit `.__await__` on the intermediate if the
# chain-end method isn't auto-awaited (here `list` is auto-awaited,
# `first` is handled by `.first` auto-await in this file).
class MockBucket
  def list(prefix)
    PromiseV2.value([{ 'key' => "#{prefix}a" }, { 'key' => "#{prefix}b" }])
  end
end
b = MockBucket.new
list = b.list('pfx-')
ok 'bucket.list returns Array (auto-awaited)', list.is_a?(Array)
ok '  — first entry key is pfx-a', list.first['key'] == 'pfx-a'

section 'Summary'
puts "\n#{$passed + $failed} tests, #{$passed} passed, #{$failed} failed"
exit($failed == 0 ? 0 : 1)
