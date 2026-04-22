# frozen_string_literal: true
# Route fragment 56 — demo /demo/sse
get '/demo/sse' do
  unless foundations_demos_enabled?
    content_type 'application/json'
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURA_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  sse do |out|
    # Manual `while` instead of `Integer#times` because Opal compiles
    # `.each` / `.times` iterators as synchronous JS `for` loops —
    # the async block returns a Promise per iteration that the loop
    # does NOT await, so all five ticks would flush as a single
    # batch (CPU ~8ms total instead of the intended ~5s). A bare
    # `while` inside a `# await: true` block compiles to a real
    # async JS loop that honours `await` between iterations.
    i = 0
    while i < 5
      out.event(
        { 'tick' => i, 'ts' => Time.now.to_i, 'note' => 'phase11a-sse' }.to_json,
        event: 'heartbeat',
        id: i.to_s
      )
      out.sleep(1)
      i += 1
    end
    out.event('done', event: 'close')
  end
end
