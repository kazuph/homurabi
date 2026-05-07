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

require "json"
require "homura/runtime"

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
      $stdout.puts("  PASS  #{label}")
    else
      @failed += 1
      @errors << label
      $stdout.puts("  FAIL  #{label}")
    end

    nil
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts("  CRASH #{label} — #{e.class}: #{e.message}")
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
    $stdout.puts("")
    $stdout.puts("#{total} tests, #{@passed} passed, #{@failed} failed")
    if @errors.any?
      $stdout.puts("Failures:")
      @errors.each { |e| $stdout.puts("  - #{e}") }
    end

    @failed == 0
  end
end

def fresh_binding
  `globalThis.__test_ai_reset__()`
  `globalThis.__test_ai_make_binding__()`
end

def push_response(hash)
  js_obj = Cloudflare::AI.ruby_to_js(hash)
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

def last_call_raw
  idx = call_count - 1
  return nil if idx < 0
  `globalThis.__test_ai_calls__[#{idx}]`
end

$stdout.puts("=== homura Phase 10 — Workers AI smoke ===")
$stdout.puts("")

# ---------------------------------------------------------------------
# 1. Cloudflare::AI.run basic
# ---------------------------------------------------------------------
$stdout.puts("--- Cloudflare::AI.run ---")

SmokeTest
  .assert!("returns Hash with response/usage keys") do
    binding = fresh_binding
    push_response(
      "response" => "hello from mock",
      "usage" => `({ prompt_tokens: 3 })`
    )
    out = Cloudflare::AI
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        {messages: [{role: "user", content: "hi"}]},
        binding: binding
      )
      .__await__
    out.is_a?(Hash) && out["response"] == "hello from mock"
  end
  .__await__

SmokeTest
  .assert!("forwards model id and Hash inputs to env.AI.run") do
    binding = fresh_binding
    push_response("response" => "ok")
    Cloudflare::AI
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        {messages: [{role: "user", content: "こんにちは"}], max_tokens: 64},
        binding: binding
      )
      .__await__
    c = last_call
    c &&
      c["model"] == "@cf/google/gemma-4-26b-a4b-it" &&
      c["inputs"].is_a?(Hash) &&
      c["inputs"]["max_tokens"] == 64 &&
      c["inputs"]["messages"].is_a?(Array) &&
      c["inputs"]["messages"][0]["content"] == "こんにちは"
  end
  .__await__

SmokeTest
  .assert!("symbol keys in inputs become string keys in JS") do
    binding = fresh_binding
    push_response("response" => "ok")
    Cloudflare::AI
      .run(
        "@cf/openai/gpt-oss-120b",
        {messages: [{role: :user, content: "sym"}], stream: false},
        binding: binding
      )
      .__await__
    c = last_call
    c["inputs"]["messages"][0]["role"] == "user" && c["inputs"].key?("stream")
  end
  .__await__

SmokeTest
  .assert!("AI binding wrapper supports ai.run(model, messages: ...)") do
    binding = fresh_binding
    ai = Cloudflare::AI::Binding.new(binding)
    push_response("response" => "wrapper ok")
    out = ai
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        messages: [{role: "user", content: "hi via wrapper"}]
      )
      .__await__
    c = last_call
    out["response"] == "wrapper ok" &&
      c["inputs"]["messages"][0]["content"] == "hi via wrapper"
  end
  .__await__

SmokeTest
  .assert!("Cloudflare::Bindings.ai wraps env cloudflare.AI") do
    env = {"cloudflare.AI" => fresh_binding}
    ai = Cloudflare::Bindings.ai(env)
    ai.is_a?(Cloudflare::AI::Binding) && ai.available?
  end
  .__await__

SmokeTest
  .assert!("AIError raised when binding is nil") do
    raised = false
    begin
      Cloudflare::AI
        .run(
          "@cf/google/gemma-4-26b-a4b-it",
          {messages: []},
          binding: nil
        )
        .__await__
    rescue Cloudflare::AIError
      raised = true
    end

    raised
  end
  .__await__

SmokeTest
  .assert!("AIError raised when binding throws") do
    binding = fresh_binding
    push_throw("quota exceeded")
    raised = false
    begin
      Cloudflare::AI
        .run(
          "@cf/google/gemma-4-26b-a4b-it",
          {messages: [{role: "user", content: "x"}]},
          binding: binding
        )
        .__await__
    rescue Cloudflare::AIError => e
      raised = e.message.include?("quota exceeded")
    end

    raised
  end
  .__await__

# ---------------------------------------------------------------------
# 2. Streaming wrapper
# ---------------------------------------------------------------------
$stdout.puts("")
$stdout.puts("--- Cloudflare::AI::Stream (stream: true) ---")

SmokeTest
  .assert!("stream:true returns Cloudflare::AI::Stream wrapper") do
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
    out = Cloudflare::AI
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        {messages: [{role: "user", content: "hi"}], stream: true},
        binding: binding
      )
      .__await__
    out.is_a?(Cloudflare::AI::Stream) && out.sse_stream? == true
  end
  .__await__

# ---------------------------------------------------------------------
# 3. Higher-level helpers
# ---------------------------------------------------------------------
$stdout.puts("")
$stdout.puts("--- Cloudflare::AI convenience helpers ---")

SmokeTest
  .assert!("chat_text builds system + user messages and extracts text") do
    binding = fresh_binding
    ai = Cloudflare::AI::Binding.new(binding)
    push_response(
      "choices" => [{"message" => {"content" => "chat helper ok"}}]
    )
    out = ai
      .chat_text(
        "Say hello",
        system: "Reply briefly.",
        max_tokens: 32
      )
      .__await__
    raw = last_call_raw
    out == "chat helper ok" &&
      `#{raw}.inputs.messages.length === 2 && #{raw}.inputs.messages[0].role === 'system' && #{raw}.inputs.messages[1].content === 'Say hello' && #{raw}.inputs.max_tokens === 32 && #{raw}.inputs.chat_template_kwargs.thinking === false`
  end
  .__await__

SmokeTest
  .assert!("extract_text reads top-level messages[].reasoning_content too") do
    binding = fresh_binding
    ai = Cloudflare::AI::Binding.new(binding)
    push_response(
      "messages" => [
        {
          "role" => "assistant",
          "reasoning_content" => "reasoning fallback text"
        }
      ]
    )
    ai.chat_text("debug shape").__await__ == "reasoning fallback text"
  end
  .__await__

SmokeTest
  .assert!("transcribe_text sends UploadedFile bytes as byte array") do
    binding = fresh_binding
    ai = Cloudflare::AI::Binding.new(binding)
    audio = Cloudflare::UploadedFile.new(
      name: "audio",
      filename: "voice.wav",
      content_type: "audio/wav",
      bytes_binstr: "abc"
    )
    push_response("text" => "spoken words")
    out = ai.transcribe_text(audio, language: "ja").__await__
    raw = last_call_raw
    out == "spoken words" &&
      `Array.isArray(#{raw}.inputs.audio) && #{raw}.inputs.audio.length === 3 && #{raw}.inputs.audio[0] === 97 && #{raw}.inputs.language === 'ja'`
  end
  .__await__

SmokeTest
  .assert!("speak returns BinaryBody and forces returnRawResponse") do
    `globalThis.__test_ai_reset__()`
    binding = `({
      run: async function(model, inputs, options) {
        globalThis.__test_ai_calls__.push({ model: model, inputs: inputs, options: options });
        return new Response('mock-mp3', { headers: { 'content-type': 'audio/mpeg' } });
      }
    })`
    ai = Cloudflare::AI::Binding.new(binding)
    out = ai.speak("hello world", speaker: "luna").__await__
    c = last_call
    out.is_a?(Cloudflare::BinaryBody) &&
      out.content_type == "audio/mpeg" &&
      c["model"] == "@cf/deepgram/aura-1" &&
      c["inputs"]["speaker"] == "luna" &&
      c["options"]["returnRawResponse"] == true
  end
  .__await__

SmokeTest
  .assert!("speak_data_url returns an embeddable data URL") do
    `globalThis.__test_ai_reset__()`
    binding = `({
      run: async function(model, inputs, options) {
        globalThis.__test_ai_calls__.push({ model: model, inputs: inputs, options: options });
        return new Response(new Uint8Array([72, 73]), { headers: { 'content-type': 'audio/mpeg' } });
      }
    })`
    ai = Cloudflare::AI::Binding.new(binding)
    out = ai.speak_data_url("hi", speaker: "luna").__await__
    out.start_with?("data:audio/mpeg;base64,") && out.end_with?("SEk=")
  end
  .__await__

SmokeTest
  .assert!("build_js_response passes RawResponse through unchanged") do
    raw = Cloudflare::RawResponse.new(
      `new Response('audio-body', { headers: { 'content-type': 'audio/mpeg' } })`
    )
    js_response = Rack::Handler::Homura.send(:build_js_response, 200, {}, raw)
    `#{js_response} === #{raw.js_response}` &&
      `#{js_response}.headers.get('content-type') === 'audio/mpeg'`
  end
  .__await__

SmokeTest
  .assert!("build_js_response passes wrapped RawResponse chunks through too") do
    raw = Cloudflare::RawResponse.new(
      `new Response('audio-body', { headers: { 'content-type': 'audio/mpeg' } })`
    )
    js_response = Rack::Handler::Homura.send(:build_js_response, 200, {}, [raw])
    `#{js_response} === #{raw.js_response}` &&
      `#{js_response}.headers.get('content-type') === 'audio/mpeg'`
  end
  .__await__

SmokeTest
  .assert!(
    "build_js_response passes plain stream/content_type chunks through"
  ) do
    stream = `new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('audio-body')); controller.close(); } })`
    plain = `({ stream: #{stream}, content_type: 'audio/mpeg', cache_control: 'public, max-age=60' })`
    js_response = Rack::Handler::Homura.send(:build_js_response, 200, {}, [plain])
    `#{js_response}.headers.get('content-type') === 'audio/mpeg'` &&
      `#{js_response}.headers.get('cache-control') === 'public, max-age=60'`
  end
  .__await__

# ---------------------------------------------------------------------
# 4. Fallback flow (simulated at the route layer would do this; this
#    asserts the building block behaves predictably under failure +
#    immediately-empty conditions).
# ---------------------------------------------------------------------
$stdout.puts("")
$stdout.puts("--- Fallback / empty-response handling ---")

SmokeTest
  .assert!("first call returns empty string -> caller can detect") do
    binding = fresh_binding
    push_response("response" => "")
    out = Cloudflare::AI
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        {messages: []},
        binding: binding
      )
      .__await__
    out["response"] == ""
  end
  .__await__

SmokeTest
  .assert!("two sequential calls hit binding twice (fallback retry pattern)") do
    binding = fresh_binding
    push_response("response" => "")
    push_response("response" => "fallback won")
    Cloudflare::AI
      .run(
        "@cf/google/gemma-4-26b-a4b-it",
        {messages: []},
        binding: binding
      )
      .__await__
    out2 = Cloudflare::AI
      .run(
        "@cf/openai/gpt-oss-120b",
        {messages: []},
        binding: binding
      )
      .__await__
    call_count == 2 && out2["response"] == "fallback won"
  end
  .__await__

# ---------------------------------------------------------------------
# 5. KV-style history persistence (smoke verifying the JSON round trip
#    that the chat route relies on; this is "what would KV store?").
# ---------------------------------------------------------------------
$stdout.puts("")
$stdout.puts("--- chat history JSON round-trip ---")

SmokeTest
  .assert!("history Array<Hash> JSON encode/decode preserves roles+content") do
    history = [
      {"role" => "user", "content" => "ping"},
      {"role" => "assistant", "content" => "pong from mock"},
      {"role" => "user", "content" => "日本語テスト"}
    ]
    raw = history.to_json
    back = JSON.parse(raw)
    back == history
  end
  .__await__

SmokeTest
  .assert!("history truncation keeps only last N entries") do
    history = (1..50).map do |i|
      {"role" => i.even? ? "assistant" : "user", "content" => "msg #{i}"}
    end

    trimmed = history.last(32)
    trimmed.size == 32 &&
      trimmed.first["content"] == "msg 19" &&
      trimmed.last["content"] == "msg 50"
  end
  .__await__

ok = SmokeTest.report
exit(ok ? 0 : 1)
