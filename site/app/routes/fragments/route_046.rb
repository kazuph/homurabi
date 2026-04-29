# frozen_string_literal: true
# Route fragment 46 — demo /demo/queue/dlq-status
get '/demo/queue/dlq-status' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled' }.to_json)
  end
  if kv.nil?
    status 503
    next({ 'error' => 'KV not bound — cannot read DLQ state' }.to_json)
  end
  limit = (params['limit'] || '10').to_i
  recent = []
  i = 0
  while i < limit
    raw = kv.get("queue:dlq:#{i}")
    break if raw.nil? || raw.empty?
    begin
      recent << JSON.parse(raw)
    rescue JSON::ParserError
      recent << { 'raw' => raw }
    end
    i += 1
  end
  {
    'queue'   => 'homura-jobs-dlq',
    'count'   => recent.size,
    'recent'  => recent
  }.to_json
end
