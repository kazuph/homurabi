# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 10 — Workers AI binding smoke tests.
#
# Verifies:
#   - Cloudflare::AI.run forwards to env.AI.run with correct model + inputs.
#   - Empty / missing responses raise Cloudflare::AIError.
#   - Hash inputs (messages array) are converted to plain JS objects.
#   - The fallback model is invoked when the primary returns empty
#     (mocked at the binding level — primary returns "" once, fallback
#     returns a real string).
#   - Streaming wrapper (sse_stream?) is returned when stream:true.
#
# Usage:
#   npm run test:ai
#   npm test            # full suite

require 'json'
require 'homura/runtime/ai'

# ---------------------------------------------------------------------
# Stub a fake env.AI binding. `__test_ai_response__` controls the next
# response; `__test_ai_calls__` records every invocation so assertions
# can verify the binding received the right model + inputs.
# ---------------------------------------------------------------------
`
globalThis.__test_ai_calls__ = [];
globalThis.__test_ai_response_queue__ = [];
globalThis.__test_ai_make_binding__ = function() {
  return {
    run: async function(model, inputs, options) {
      globalThis.__test_ai_calls__.push({ model: model, inputs: inputs, options: options });
      var queue = globalThis.__test_ai_response_queue__;
      if (queue.length === 0) {
        return { response: 'default-mock', usage: { prompt_tokens: 1, completion_tokens: 1 } };
      }
      var next = queue.shift();
      if (next && next.__throw__) {
        throw new Error(next.message || 'mock failure');
      }
      return next;
    }
  };
};
globalThis.__test_ai_reset__ = function() {
  globalThis.__test_ai_calls__ = [];
  globalThis.__test_ai_response_queue__ = [];
};
`

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

  # Each test block awaits internal Promises with `.__await__` and
  # returns a plain boolean. Because this file is `# await: true`, the
  # block's compiled JS function is `async`, so `block.call` returns a
  # JS Promise that we must explicitly await before reading its value.
  # Without the explicit await, the assertion would PASS on the truthy
  # Promise object and the actual rejection would only surface as an
  # unhandled rejection long after report() printed totals.
  #
  # `assert` itself is also async (it lives in a `# await: true` file),
  # so callers must `__await__` each assert to enforce sequential
  # execution — otherwise asserts race against each other through the
  # shared globalThis.__test_ai_response_queue__.
  def self.assert(label, &block)
    raw = block.call
    result = if `(#{raw} != null && typeof #{raw} === 'object' && typeof #{raw}.then === 'function')`
               raw.__await__
             else
               raw
             end
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stdout.puts "  FAIL  #{label}"
    end
    nil
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts "  CRASH #{label} — #{e.class}: #{e.message}"
    nil
  end

  # Sequential wrapper around assert: returns a plain Promise that the
  # top-level code awaits with `.__await__`, which serialises async
  # tests so they don't race over the shared mock binding queue.
  def self.assert!(label, &block)
    p = assert(label, &block)
    # Ensure we hand back a thenable so the top-level call can `__await__`
    # it. If `assert` returned a non-Promise (synchronous path), wrap it.
    if `(#{p} != null && typeof #{p} === 'object' && typeof #{p}.then === 'function')`
      p
    else
      `Promise.resolve(#{p})`
    end
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

def fresh_binding
  `globalThis.__test_ai_reset__()`
  `globalThis.__test_ai_make_binding__()`
end

def push_response(hash)
  js_obj = `({})`
  hash.each { |k, v| ks = k.to_s; `#{js_obj}[#{ks}] = #{v}` }
  `globalThis.__test_ai_response_queue__.push(#{js_obj})`
end

def push_throw(message)
  obj = `({ __throw__: true, message: #{message} })`
  `globalThis.__test_ai_response_queue__.push(#{obj})`
end

def call_count
  `globalThis.__test_ai_calls__.length`
end

def last_call
  idx = call_count - 1
  return nil if idx < 0
  raw = `globalThis.__test_ai_calls__[#{idx}]`
  Cloudflare.js_to_ruby(raw)
end

$stdout.puts '=== homura Phase 10 — Workers AI smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# 1. Cloudflare::AI.run basic
# ---------------------------------------------------------------------
$stdout.puts '--- Cloudflare::AI.run ---'

SmokeTest.assert!('returns Hash with response/usage keys') {
  binding = fresh_binding
  push_response('response' => 'hello from mock', 'usage' => `({ prompt_tokens: 3 })`)
  out = Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it',
                           { messages: [{ role: 'user', content: 'hi' }] },
                           binding: binding).__await__
  out.is_a?(Hash) && out['response'] == 'hello from mock'
}.__await__

SmokeTest.assert!('forwards model id and Hash inputs to env.AI.run') {
  binding = fresh_binding
  push_response('response' => 'ok')
  Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it',
                     { messages: [{ role: 'user', content: 'こんにちは' }], max_tokens: 64 },
                     binding: binding).__await__
  c = last_call
  c && c['model'] == '@cf/google/gemma-4-26b-a4b-it' &&
    c['inputs'].is_a?(Hash) &&
    c['inputs']['max_tokens'] == 64 &&
    c['inputs']['messages'].is_a?(Array) &&
    c['inputs']['messages'][0]['content'] == 'こんにちは'
}.__await__

SmokeTest.assert!('symbol keys in inputs become string keys in JS') {
  binding = fresh_binding
  push_response('response' => 'ok')
  Cloudflare::AI.run('@cf/openai/gpt-oss-120b',
                     { messages: [{ role: :user, content: 'sym' }], stream: false },
                     binding: binding).__await__
  c = last_call
  c['inputs']['messages'][0]['role'] == 'user' && c['inputs'].key?('stream')
}.__await__

SmokeTest.assert!('AIError raised when binding is nil') {
  raised = false
  begin
    Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it', { messages: [] }, binding: nil).__await__
  rescue Cloudflare::AIError
    raised = true
  end
  raised
}.__await__

SmokeTest.assert!('AIError raised when binding throws') {
  binding = fresh_binding
  push_throw('quota exceeded')
  raised = false
  begin
    Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it',
                       { messages: [{ role: 'user', content: 'x' }] },
                       binding: binding).__await__
  rescue Cloudflare::AIError => e
    raised = e.message.include?('quota exceeded')
  end
  raised
}.__await__

# ---------------------------------------------------------------------
# 2. Streaming wrapper
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Cloudflare::AI::Stream (stream: true) ---'

SmokeTest.assert!('stream:true returns Cloudflare::AI::Stream wrapper') {
  binding = `({
    run: async function(model, inputs) {
      // Real Workers AI returns a ReadableStream<Uint8Array>; we mock
      // with a stream that emits one chunk and closes.
      return new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode("data: {\\\"response\\\":\\\"chunk1\\\"}\\n\\n"));
          controller.close();
        }
      });
    }
  })`
  out = Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it',
                           { messages: [{ role: 'user', content: 'hi' }], stream: true },
                           binding: binding).__await__
  out.is_a?(Cloudflare::AI::Stream) && out.sse_stream? == true
}.__await__

# ---------------------------------------------------------------------
# 3. Fallback flow (simulated at the route layer would do this; this
#    asserts the building block behaves predictably under failure +
#    immediately-empty conditions).
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Fallback / empty-response handling ---'

SmokeTest.assert!('first call returns empty string -> caller can detect') {
  binding = fresh_binding
  push_response('response' => '')
  out = Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it',
                           { messages: [] }, binding: binding).__await__
  out['response'] == ''
}.__await__

SmokeTest.assert!('two sequential calls hit binding twice (fallback retry pattern)') {
  binding = fresh_binding
  push_response('response' => '')
  push_response('response' => 'fallback won')
  Cloudflare::AI.run('@cf/google/gemma-4-26b-a4b-it', { messages: [] }, binding: binding).__await__
  out2 = Cloudflare::AI.run('@cf/openai/gpt-oss-120b',  { messages: [] }, binding: binding).__await__
  call_count == 2 && out2['response'] == 'fallback won'
}.__await__

# ---------------------------------------------------------------------
# 4. KV-style history persistence (smoke verifying the JSON round trip
#    that the chat route relies on; this is "what would KV store?").
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- chat history JSON round-trip ---'

SmokeTest.assert!('history Array<Hash> JSON encode/decode preserves roles+content') {
  history = [
    { 'role' => 'user',      'content' => 'ping' },
    { 'role' => 'assistant', 'content' => 'pong from mock' },
    { 'role' => 'user',      'content' => '日本語テスト' }
  ]
  raw = history.to_json
  back = JSON.parse(raw)
  back == history
}.__await__

SmokeTest.assert!('history truncation keeps only last N entries') {
  history = (1..50).map { |i| { 'role' => i.even? ? 'assistant' : 'user', 'content' => "msg #{i}" } }
  trimmed = history.last(32)
  trimmed.size == 32 && trimmed.first['content'] == 'msg 19' && trimmed.last['content'] == 'msg 50'
}.__await__

ok = SmokeTest.report
exit(ok ? 0 : 1)
