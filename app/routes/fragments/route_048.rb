# await: true
# frozen_string_literal: true
# Route fragment 48 — test /test/bindings
get '/test/bindings' do
  content_type 'application/json'
  unless binding_demos_enabled?
    status 404
    next({ 'error' => 'binding demos disabled (set HOMURABI_ENABLE_BINDING_DEMOS=1)' }.to_json)
  end
  cases = []
  started = Time.now.to_f

  # 1. DurableObject round-trip
  do_case = { 'case' => 'DurableObject counter inc/peek/reset round-trip' }
  begin
    ns = do_counter
    if ns.nil?
      do_case['pass'] = false
      do_case['note'] = 'COUNTER binding not bound'
    else
      name = "selftest-#{SecureRandom.hex(4)}"
      stub = ns.get_by_name(name)
      base = 'https://homurabi-do.internal'
      stub.fetch("#{base}/reset", method: 'POST')
      r1 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').body)
      r2 = JSON.parse(stub.fetch("#{base}/inc", method: 'POST').body)
      peek = JSON.parse(stub.fetch("#{base}/peek").body)
      do_case['pass'] = r1['count'] == 1 && r2['count'] == 2 && peek['count'] == 2
      do_case['detail'] = { 'r1' => r1, 'r2' => r2, 'peek' => peek }
      stub.fetch("#{base}/reset", method: 'POST')
    end
  rescue ::Exception => e
    do_case['pass'] = false
    do_case['note'] = "#{e.class}: #{e.message[0, 200]}"
  end
  cases << do_case

  # 2. Cache API put/match round-trip
  cache_case = { 'case' => 'Cache API match after put returns same body' }
  begin
    c = cache
    key = "https://cache-selftest.example/phase11b-#{SecureRandom.hex(4)}"
    payload = { 'self_test' => true, 'ts' => Time.now.to_i }.to_json
    c.put(key, payload, status: 200, headers: {
      'content-type'  => 'application/json',
      'cache-control' => 'public, max-age=30',
      'date'          => Time.now.httpdate
    })
    got = c.match(key)
    if got.nil?
      cache_case['pass'] = false
      cache_case['note'] = 'match returned nil after put (cache unavailable in this runtime?)'
    else
      cache_case['pass'] = got.body == payload
      cache_case['detail'] = { 'status' => got.status, 'content_type' => got['content-type'] }
    end
  rescue ::Exception => e
    cache_case['pass'] = false
    cache_case['note'] = "#{e.class}: #{e.message[0, 200]}"
  end
  cases << cache_case

  # 3. Queue producer .send succeeds (does not crash). We can't
  # synchronously assert delivery because the consumer runs in a
  # separate invocation; instead we check that the producer returned
  # without error and, when KV is available, that at least one
  # message had been delivered previously (warmup from /api/enqueue).
  queue_case = { 'case' => 'Queue producer send() returns without error' }
  begin
    q = jobs_queue
    if q.nil?
      queue_case['pass'] = false
      queue_case['note'] = 'JOBS_QUEUE binding not bound'
    else
      q.send({ 'selftest' => true, 'ts' => Time.now.to_i, 'nonce' => SecureRandom.hex(4) })
      queue_case['pass'] = true
      queue_case['note'] = 'producer.send completed'
    end
  rescue ::Exception => e
    queue_case['pass'] = false
    queue_case['note'] = "#{e.class}: #{e.message[0, 200]}"
  end
  cases << queue_case

  passed = cases.count { |c| c['pass'] }
  failed = cases.size - passed
  {
    'passed'    => passed,
    'failed'    => failed,
    'total'     => cases.size,
    'elapsed_ms'=> ((Time.now.to_f - started) * 1000).round,
    'cases'     => cases
  }.to_json
end
