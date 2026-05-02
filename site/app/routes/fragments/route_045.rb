# frozen_string_literal: true
# Route fragment 45 — test /test/queue/fire
post '/test/queue/fire' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled' }.to_json)
  end
  body = begin
    JSON.parse(request.body.read)
  rescue StandardError
    {}
  end
  qname = (body['queue'] || 'homura-jobs').to_s
  messages = body['messages'].is_a?(Array) ? body['messages'] : [{ 'fire' => true, 'ts' => Time.now.to_i }]

  js_msgs = `([])`
  idx = 0
  messages.each do |m|
    js_body = Cloudflare::AI.ruby_to_js(m)
    i_str = "manual-#{Time.now.to_i}-#{idx}"
    now_ms = (Time.now.to_f * 1000).to_i
    `#{js_msgs}.push({ id: #{i_str}, timestamp: new Date(#{now_ms}), body: #{js_body}, ack: function() {}, retry: function() {} })`
    idx += 1
  end
  js_batch = `({ queue: #{qname}, messages: #{js_msgs}, ackAll: function() {}, retryAll: function() {} })`
  summary = Cloudflare::QueueConsumer.dispatch_js(js_batch, cf_env, cf_ctx)
  summary.merge('injected' => messages.size).to_json
end
