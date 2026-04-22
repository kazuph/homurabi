# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
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
  qname = (body['queue'] || 'homurabi-jobs').to_s
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
  summary = Cloudflare::QueueConsumer.dispatch_js(js_batch, env['cloudflare.env'], env['cloudflare.ctx'])
  summary.merge('injected' => messages.size).to_json
end
