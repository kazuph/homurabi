# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Queues binding smoke tests.
#
# Covers the full producer + consumer surface:
#
#   1. Cloudflare::Queue#send forwards body + options to js.send.
#   2. Cloudflare::Queue#send_batch forwards sendBatch and accepts
#      Hash and plain-value message forms.
#   3. Queue raises QueueError when the binding is nil.
#   4. QueueMessage exposes body, id, ack, retry.
#   5. QueueBatch#messages maps JS messages to QueueMessage wrappers,
#      and #ack_all / #retry_all forward to the JS batch.
#   6. consume_queue DSL (Sinatra::Queue) registers a handler that
#      the dispatcher picks up by queue name.
#   7. globalThis.__HOMURA_QUEUE_DISPATCH__ is installed and runs
#      the Ruby handler when invoked by JS.

require 'json'
require 'homura/runtime'
require 'sinatra/base'
require 'sinatra/queue'

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
# Fake binding factories — defined as globalThis functions so the
# single-line backtick in the Ruby helper returns the constructed
# object (Opal treats multi-line x-strings as statements).
# ---------------------------------------------------------------------

`globalThis.__homura_queue_fake_producer = function() { var p = { _sends: [], _batches: [], send: function(body, opts) { p._sends.push({ body: body, opts: opts || {} }); return Promise.resolve(); }, sendBatch: function(msgs, opts) { p._batches.push({ msgs: msgs, opts: opts || {} }); return Promise.resolve(); } }; return p; };`

`globalThis.__homura_queue_fake_batch = function(queue_name, bodies) { var calls = { acks: 0, retries: 0, ackAll: 0, retryAll: 0 }; var msgs = bodies.map(function(b, i) { return { id: 'mid-' + i, timestamp: new Date(1700000000000 + i * 1000), body: b, ack: function() { calls.acks += 1; }, retry: function(opts) { calls.retries += 1; this._retryOpts = opts; } }; }); return { queue: queue_name, messages: msgs, ackAll: function() { calls.ackAll += 1; }, retryAll: function(opts) { calls.retryAll += 1; this._retryAllOpts = opts; }, __calls: calls }; };`

def fake_queue_producer
  `globalThis.__homura_queue_fake_producer()`
end

def fake_batch(queue_name, bodies)
  js_bodies = `[]`
  bodies.each { |b| `#{js_bodies}.push(#{b})` }
  qname = queue_name.to_s
  `globalThis.__homura_queue_fake_batch(#{qname}, #{js_bodies})`
end

$stdout.puts '=== homura Phase 11B — Queue smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# 1. Queue#send
# ---------------------------------------------------------------------
$stdout.puts '--- Queue#send ---'

SmokeTest.assert('send forwards a Hash body as a JS object') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send({ 'name' => 'alice', 'n' => 3 }).__await__
  entry = `#{js_p}._sends[0]`
  name = `#{entry}.body.name`
  n = `#{entry}.body.n`
  name == 'alice' && n == 3
end

SmokeTest.assert('send forwards a plain String body untouched') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send('hello-string').__await__
  `#{js_p}._sends[0].body` == 'hello-string'
end

SmokeTest.assert('send with delay_seconds forwards opts.delaySeconds') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send({ 'n' => 1 }, delay_seconds: 30).__await__
  `#{js_p}._sends[0].opts.delaySeconds` == 30
end

SmokeTest.assert('send with content_type forwards opts.contentType') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send('bytes-here', content_type: 'bytes').__await__
  `#{js_p}._sends[0].opts.contentType` == 'bytes'
end

SmokeTest.assert('send on a nil binding raises QueueError') do
  q = Cloudflare::Queue.new(nil, 'jobs')
  raised = false
  begin
    q.send('x').__await__
  rescue Cloudflare::QueueError => e
    raised = e.message.include?('not bound')
  end
  raised
end

SmokeTest.assert('send propagates JS rejection as QueueError') do
  bad = `({ send: function() { return Promise.reject(new Error('producer-kaboom')); } })`
  q = Cloudflare::Queue.new(bad, 'jobs')
  raised = false
  begin
    q.send({ 'x' => 1 }).__await__
  rescue Cloudflare::QueueError => e
    raised = e.message.include?('producer-kaboom')
  end
  raised
end

# ---------------------------------------------------------------------
# 2. Queue#send_batch
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Queue#send_batch ---'

SmokeTest.assert('send_batch accepts a list of plain bodies') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send_batch(['a', 'b', 'c']).__await__
  msgs = `#{js_p}._batches[0].msgs`
  `#{msgs}.length` == 3 && `#{msgs}[0].body` == 'a' && `#{msgs}[2].body` == 'c'
end

SmokeTest.assert('send_batch preserves order + count across 100 messages') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  msgs = (1..100).map { |i| { 'seq' => i, 'tag' => "t-#{i}" } }
  q.send_batch(msgs).__await__
  arr = `#{js_p}._batches[0].msgs`
  ok = `#{arr}.length` == 100
  if ok
    # Random sample ordering to catch reordering bugs without iterating
    # every message. 0 / 42 / 99 covers start/middle/end.
    ok &&= `#{arr}[0].body.seq`   == 1   && `#{arr}[0].body.tag`   == 't-1'
    ok &&= `#{arr}[42].body.seq`  == 43  && `#{arr}[42].body.tag`  == 't-43'
    ok &&= `#{arr}[99].body.seq`  == 100 && `#{arr}[99].body.tag`  == 't-100'
  end
  ok
end

SmokeTest.assert('send_batch with delay_seconds forwards top-level opts.delaySeconds') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send_batch(['a', 'b', 'c'], delay_seconds: 17).__await__
  `#{js_p}._batches[0].opts.delaySeconds` == 17
end

SmokeTest.assert('send_batch accepts Hash messages with body + options') do
  js_p = fake_queue_producer
  q = Cloudflare::Queue.new(js_p, 'jobs')
  q.send_batch([
    { 'body' => { 'x' => 1 }, 'content_type' => 'json' },
    { 'body' => 'plain',      'delay_seconds' => 10 }
  ]).__await__
  msgs = `#{js_p}._batches[0].msgs`
  `#{msgs}[0].body.x` == 1 && `#{msgs}[0].contentType` == 'json' &&
    `#{msgs}[1].body` == 'plain' && `#{msgs}[1].delaySeconds` == 10
end

# ---------------------------------------------------------------------
# 3. QueueMessage
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- QueueMessage ---'

SmokeTest.assert('QueueMessage#body returns a Ruby Hash when the JS message body is an object') do
  js_msg = `({ id: 'm1', timestamp: new Date(1700000000000), body: { title: 'first', n: 7 }, ack: function(){}, retry: function(){} })`
  msg = Cloudflare::QueueMessage.new(js_msg)
  msg.body.is_a?(Hash) && msg.body['title'] == 'first' && msg.body['n'] == 7
end

SmokeTest.assert('QueueMessage#id and #timestamp surface the JS fields as Ruby types') do
  js_msg = `({ id: 'mid-42', timestamp: new Date(1700000000000), body: 'x', ack: function(){}, retry: function(){} })`
  msg = Cloudflare::QueueMessage.new(js_msg)
  msg.id == 'mid-42' && msg.timestamp.is_a?(Time) && msg.timestamp.to_i == 1_700_000_000
end

SmokeTest.assert('QueueMessage#ack calls js.ack exactly once') do
  batch = fake_batch('jobs', [`({ v: 1 })`])
  msgs = Cloudflare::QueueBatch.new(batch).messages
  msgs.first.ack
  `#{batch}.__calls.acks` == 1
end

SmokeTest.assert('QueueMessage#retry with delay_seconds forwards options.delaySeconds') do
  batch = fake_batch('jobs', [`({ v: 1 })`])
  msgs = Cloudflare::QueueBatch.new(batch).messages
  msgs.first.retry(delay_seconds: 7)
  opts = `#{batch}.messages[0]._retryOpts`
  `#{opts} && #{opts}.delaySeconds === 7`
end

# ---------------------------------------------------------------------
# 4. QueueBatch
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- QueueBatch ---'

SmokeTest.assert('QueueBatch#queue and #size reflect the JS batch') do
  batch = fake_batch('the-queue', [`({ a: 1 })`, `({ b: 2 })`, `({ c: 3 })`])
  b = Cloudflare::QueueBatch.new(batch)
  b.queue == 'the-queue' && b.size == 3
end

SmokeTest.assert('QueueBatch#ack_all calls js.ackAll exactly once') do
  batch = fake_batch('jobs', [`({ a: 1 })`])
  Cloudflare::QueueBatch.new(batch).ack_all
  `#{batch}.__calls.ackAll` == 1
end

SmokeTest.assert('QueueBatch#retry_all with delay_seconds forwards options.delaySeconds') do
  batch = fake_batch('jobs', [`({ a: 1 })`])
  Cloudflare::QueueBatch.new(batch).retry_all(delay_seconds: 42)
  opts = `#{batch}._retryAllOpts`
  `#{opts} && #{opts}.delaySeconds === 42`
end

# ---------------------------------------------------------------------
# 5. consume_queue DSL + dispatcher
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- consume_queue DSL + dispatcher ---'

SmokeTest.assert('consume_queue registers a handler retrievable via QueueConsumer.handler_for') do
  app = Class.new(Sinatra::Base) do
    register Sinatra::Queue
    consume_queue('unit-test-queue') { |batch| batch.size }
  end
  _ = app
  !Cloudflare::QueueConsumer.handler_for('unit-test-queue').nil?
end

SmokeTest.assert('dispatcher invokes the registered consume_queue handler with the QueueBatch') do
  counter = { 'count' => 0, 'queue' => nil, 'ids' => [] }
  Class.new(Sinatra::Base) do
    register Sinatra::Queue
    consume_queue('smoke-queue') do |batch|
      counter['queue'] = batch.queue
      batch.messages.each do |m|
        counter['count'] += 1
        counter['ids'] << m.id
        m.ack
      end
    end
  end
  batch = fake_batch('smoke-queue', [`({ n: 1 })`, `({ n: 2 })`])
  summary = Cloudflare::QueueConsumer.dispatch_js(batch, `({})`, `({})`).__await__
  counter['count'] == 2 && counter['queue'] == 'smoke-queue' &&
    counter['ids'] == ['mid-0', 'mid-1'] &&
    summary['queue'] == 'smoke-queue' && summary['handled'] == true
end

SmokeTest.assert('dispatcher for an unregistered queue name returns handled=false') do
  batch = fake_batch('never-registered', [`({ n: 1 })`])
  summary = Cloudflare::QueueConsumer.dispatch_js(batch, `({})`, `({})`).__await__
  summary['handled'] == false && summary['reason'] == 'no_handler'
end

# ---------------------------------------------------------------------
# 6. JS dispatcher hook
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- JS dispatcher hook ---'

SmokeTest.assert('globalThis.__HOMURA_QUEUE_DISPATCH__ is installed') do
  `typeof globalThis.__HOMURA_QUEUE_DISPATCH__ === 'function'`
end

SmokeTest.assert('JS hook forwards through to the Ruby handler') do
  bucket = { 'fired' => 0 }
  Class.new(Sinatra::Base) do
    register Sinatra::Queue
    consume_queue('via-js-hook') { |batch| bucket['fired'] += batch.size }
  end
  batch = fake_batch('via-js-hook', [`({})`, `({})`, `({})`])
  promise = `globalThis.__HOMURA_QUEUE_DISPATCH__(#{batch}, ({}), ({}))`
  summary = promise.__await__
  bucket['fired'] == 3 && summary['handled'] == true
end

success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
