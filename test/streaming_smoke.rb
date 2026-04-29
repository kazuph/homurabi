# frozen_string_literal: true
# await: true
# backtick_javascript: true
#
# Cloudflare::SSEStream / SSEOut smoke tests.

require 'homura/runtime/stream'

module StreamingSmoke
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    r = block.call
    if r
      @passed += 1; $stdout.puts "  PASS  #{label}"
    else
      @failed += 1; @errors << label; $stdout.puts "  FAIL  #{label}"
    end
  rescue Exception => e
    @failed += 1; @errors << "#{label} (#{e.class}: #{e.message})"
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

# Drain a JS ReadableStream to a Ruby String via TextDecoder. Runs
# entirely in JS (single-line IIFE) to sidestep Opal's async-loop
# compilation quirks — a Ruby `loop do … end` containing `__await__`
# allocates a Promise per iteration and does NOT break cleanly under
# the async transformation, which blew up the Node heap the first time.
def drain_readable(js_stream)
  `(async function(stream) { var reader = stream.getReader(); var decoder = new TextDecoder(); var out = ''; while (true) { var r = await reader.read(); if (r.done) return out; out += decoder.decode(r.value); } })(#{js_stream})`.__await__
end

$stdout.puts "=== Streaming smoke tests ==="

# 1. Static framing: write `data: x\n\n` via <<
StreamingSmoke.assert('SSEOut << writes raw chunk to the stream') {
  ts = `new TransformStream()`
  writer = `#{ts}.writable.getWriter()`
  out = Cloudflare::SSEOut.new(writer)
  out << "data: hello\n\n"
  out.close
  decoded = drain_readable(`#{ts}.readable`).__await__
  decoded == "data: hello\n\n"
}

# 2. SSEOut#event produces well-formed event payload (event: / id: / data:)
StreamingSmoke.assert('SSEOut#event emits event: / id: / data: frame') {
  ts = `new TransformStream()`
  writer = `#{ts}.writable.getWriter()`
  out = Cloudflare::SSEOut.new(writer)
  out.event('hello', event: 'greet', id: '42')
  out.close
  decoded = drain_readable(`#{ts}.readable`).__await__
  decoded.include?('event: greet') &&
    decoded.include?('id: 42') &&
    decoded.include?('data: hello') &&
    decoded.end_with?("\n\n")
}

# 3. Multi-line data split across multiple `data:` lines
StreamingSmoke.assert('SSEOut#event splits multi-line data on \n') {
  ts = `new TransformStream()`
  writer = `#{ts}.writable.getWriter()`
  out = Cloudflare::SSEOut.new(writer)
  out.event("line-one\nline-two")
  out.close
  decoded = drain_readable(`#{ts}.readable`).__await__
  decoded.include?('data: line-one') && decoded.include?('data: line-two')
}

# 4. Comments (`: keep-alive`) flow through
StreamingSmoke.assert('SSEOut#comment emits : comment frame') {
  ts = `new TransformStream()`
  writer = `#{ts}.writable.getWriter()`
  out = Cloudflare::SSEOut.new(writer)
  out.comment('keep-alive')
  out.close
  decoded = drain_readable(`#{ts}.readable`).__await__
  decoded == ": keep-alive\n\n"
}

# 5. Closed stream swallows further writes (no crash, no data)
StreamingSmoke.assert('writes after close are no-ops') {
  ts = `new TransformStream()`
  writer = `#{ts}.writable.getWriter()`
  out = Cloudflare::SSEOut.new(writer)
  out << "a"
  out.close
  # second close + write should not raise
  out.close
  out << "b"
  decoded = drain_readable(`#{ts}.readable`).__await__
  decoded == 'a'
}

# 6. SSEStream.new raises ArgumentError when given no block
StreamingSmoke.assert('SSEStream.new { |out| … } must receive a block') {
  s = Cloudflare::SSEStream.new
  raised = nil
  begin
    s.js_stream
  rescue ArgumentError => e
    raised = e
  end
  !raised.nil?
}

# 7. SSEStream end-to-end: block writes 3 events, stream closes, output is complete
StreamingSmoke.assert('SSEStream end-to-end: block emits 3 events, then closes') {
  s = Cloudflare::SSEStream.new do |out|
    3.times do |i|
      out.event("tick-#{i}", event: 'heartbeat', id: i.to_s)
    end
  end
  readable = s.js_stream
  decoded = drain_readable(readable).__await__
  %w[tick-0 tick-1 tick-2].all? { |v| decoded.include?("data: #{v}") } &&
    decoded.count('event: heartbeat') == 3
}

# 8. SSEStream handles exceptions inside the block (stream still closes)
StreamingSmoke.assert('exception in block closes the stream cleanly') {
  s = Cloudflare::SSEStream.new do |out|
    out << "partial\n"
    raise 'deliberate'
  end
  readable = s.js_stream
  # drain_readable hits 'done' because stream closes in ensure.
  decoded = drain_readable(readable).__await__
  decoded.include?('partial')
}

# 9. sse_stream? duck-type is honoured by build_js_response
StreamingSmoke.assert('SSEStream#sse_stream? is true') {
  Cloudflare::SSEStream.new { |_o| }.sse_stream?
}

# 10. Default headers include the SSE content-type
StreamingSmoke.assert('SSEStream#response_headers advertises text/event-stream') {
  h = Cloudflare::SSEStream.new { |_o| }.response_headers
  h['content-type'].include?('text/event-stream') &&
    h['cache-control'].include?('no-cache')
}

# 11. Custom headers merge over defaults
StreamingSmoke.assert('SSEStream extra headers merge over defaults') {
  h = Cloudflare::SSEStream.new(headers: { 'x-phase' => '11a' }) { |_o| }.response_headers
  h['x-phase'] == '11a' && h['content-type'].include?('text/event-stream')
}

# 12. Sinatra::Streaming#stream(type: :plain) uses text/plain
StreamingSmoke.assert('Sinatra::Streaming#stream type: :plain emits text/plain body') {
  # Minimal stub Sinatra context
  ctx_stub = Class.new {
    include Sinatra::Streaming
    def env; {}; end
  }.new
  s = ctx_stub.stream(type: :plain) { |o| o << "hi"; o.close }
  s.is_a?(Cloudflare::SSEStream) && s.response_headers['content-type'].include?('text/plain')
}

# 13. Sinatra::Streaming#stream(type: :sse) uses SSE defaults
StreamingSmoke.assert('Sinatra::Streaming#stream type: :sse emits event-stream headers') {
  ctx_stub = Class.new {
    include Sinatra::Streaming
    def env; {}; end
  }.new
  s = ctx_stub.stream(type: :sse) { |o| o.close }
  s.response_headers['content-type'].include?('text/event-stream')
}

# 14. Sinatra::Base#stream (upstream-compat override) builds an SSEStream
require 'sinatra/base'
StreamingSmoke.assert('Sinatra::Base#stream override returns Cloudflare::SSEStream') {
  app = Class.new(Sinatra::Base) do
    get '/test-stream' do
      stream do |out|
        out << "hello"
      end
    end
  end
  # We don't actually dispatch — just verify the override is installed.
  inst = app.new!
  inst.instance_variable_set(:@env, {})
  # Calling stream directly with a block returns the SSEStream.
  s = inst.stream { |o| o << "x" }
  s.is_a?(Cloudflare::SSEStream)
}

success = StreamingSmoke.report
`process.exit(#{success ? 0 : 1})`
