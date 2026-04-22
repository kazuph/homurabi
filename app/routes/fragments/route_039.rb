# await: true
# frozen_string_literal: true
# Route fragment 39 — demo /demo/do/ws
get '/demo/do/ws' do
  unless binding_demos_enabled?
    status 404
    content_type 'application/json'
    next({ 'error' => 'binding demos disabled' }.to_json)
  end
  # Copilot review PR #9 (third pass): Workers only accepts a
  # `Response` with a `.webSocket` property from a handler that
  # was invoked by a real WebSocket-upgrade request. If a plain
  # `curl` (no Upgrade header) hits this route, forwarding to the
  # DO stub causes the runtime to throw ("Response with webSocket
  # requires a WebSocket request"), surfacing as a confusing 500.
  # Reject non-upgrade requests up-front with a 426 so clients
  # get an intentional, documented response.
  upgrade = (request.env['HTTP_UPGRADE'] || '').to_s.downcase
  unless upgrade == 'websocket'
    status 426
    content_type 'application/json'
    next({
      'error' => 'Upgrade Required',
      'detail' => 'GET /demo/do/ws must be called with `Upgrade: websocket`; use a WebSocket client.'
    }.to_json)
  end
  ns = do_counter
  if ns.nil?
    status 503
    content_type 'application/json'
    next({ 'error' => 'COUNTER binding not bound' }.to_json)
  end
  name = (params['name'] || 'ws-demo').to_s
  stub = ns.get_by_name(name)
  # Forward a WebSocket-upgrade request to the DO stub. The stub's
  # fetch() returns a 101 Response with `.webSocket` attached;
  # Cloudflare::RawResponse signals to build_js_response that the
  # JS Response must be passed through untouched (normal bodies
  # lose the WebSocket property when reconstructed).
  js_resp = stub.fetch_raw(
    "https://homurabi-do.internal/ws/#{name}",
    method: 'GET',
    headers: { 'upgrade' => 'websocket' }
  )
  Cloudflare::RawResponse.new(js_resp)
end
