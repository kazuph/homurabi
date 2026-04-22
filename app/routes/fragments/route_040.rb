# frozen_string_literal: true
# Route fragment 40 — demo /demo/do
get '/demo/do' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled (set HOMURA_ENABLE_BINDING_DEMOS=1)' }.to_json)
  end
  ns = do_counter
  if ns.nil?
    status 503
    next({ 'error' => 'DurableObject binding COUNTER not bound (wrangler.toml missing [[durable_objects.bindings]])' }.to_json)
  end
  name = (params['name'] || 'global').to_s
  action = (params['action'] || 'inc').to_s
  stub = ns.get_by_name(name)
  # `stub.fetch` requires an absolute URL — the Workers runtime
  # parses the URL to route the call. The host is irrelevant (the
  # DO receives the whole Request), but it must be parseable.
  url = "https://homura-do.internal/#{action}"
  res = stub.fetch(url, method: 'POST')
  {
    'demo'    => 'Durable Objects counter',
    'binding' => 'COUNTER',
    'class'   => 'HomuraCounterDO',
    'name'    => name,
    'action'  => action,
    'status'  => res.status,
    'body'    => res.body.empty? ? nil : JSON.parse(res.body)
  }.to_json
end
