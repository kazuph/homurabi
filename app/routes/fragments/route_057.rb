# frozen_string_literal: true
# Route fragment 57 — test /test/foundations
get '/test/foundations' do
  content_type 'application/json'
  unless foundations_demos_enabled?
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURA_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end

  cases = []
  run = lambda { |label, &blk|
    result = begin
      v = blk.call
      v == false ? { 'pass' => false, 'note' => 'returned false' } : { 'pass' => true }
    rescue ::Exception => e
      { 'pass' => false, 'note' => "#{e.class}: #{e.message[0, 200]}" }
    end
    cases << result.merge('case' => label)
  }

  # Faraday GET with :json middleware, hitting the only stable public
  # API we're willing to depend on in a self-test (ipify). httpbin.org
  # was tried here earlier and blew up the Workers isolate with
  # "Reached heap limit" — the body comes back huge and JSON-parsing
  # it inside Opal is not free.
  run.call('Faraday GET with :json middleware round-trips') {
    c = Faraday.new(url: 'https://api.ipify.org') do |conn|
      conn.request :json
      conn.response :json
    end
    res = c.get('/', { 'format' => 'json' })
    res.success? && res.body.is_a?(Hash) && res.body['ip']
  }

  # :raise_error + Faraday.new on an existing URL that returns non-2xx.
  # We don't hit httpbin (too heavy), so use an obviously-404 path on
  # ipify which always responds 404 with a short body.
  run.call('Faraday raise_error raises ResourceNotFound on 404') {
    c = Faraday.new(url: 'https://api.ipify.org') do |conn|
      conn.response :raise_error
    end
    raised = nil
    begin
      c.get('/this-path-does-not-exist-11a')
    rescue Faraday::ResourceNotFound => e
      raised = e
    end
    raised && raised.response_status == 404
  }

  # Offline test — the :json request middleware must encode a Hash
  # body as JSON without hitting the network. We inspect the Env
  # directly instead of a live round-trip.
  run.call('Faraday :json middleware encodes Hash body (offline)') {
    env = Faraday::Env.new(method: :post, url: 'https://example.com/x')
    env.body = { 'name' => 'homura', 'phase' => 11 }
    Faraday::Middleware::JSON.new.on_request(env)
    env.body == '{"name":"homura","phase":11}' &&
      env.request_headers['content-type'] == 'application/json'
  }

  run.call('Multipart parser extracts file + text field') {
    boundary = '----phase11atest'
    body = ''
    body += "--#{boundary}\r\n"
    body += "Content-Disposition: form-data; name=\"note\"\r\n\r\n"
    body += "hello-11a\r\n"
    body += "--#{boundary}\r\n"
    body += "Content-Disposition: form-data; name=\"file\"; filename=\"t.bin\"\r\n"
    body += "Content-Type: application/octet-stream\r\n\r\n"
    body += "\x00\x01\x02payload"
    body += "\r\n--#{boundary}--\r\n"
    parsed = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{boundary}")
    parsed['note'] == 'hello-11a' &&
      parsed['file'].is_a?(Cloudflare::UploadedFile) &&
      parsed['file'].filename == 't.bin' &&
      parsed['file'].size == "\x00\x01\x02payload".length
  }

  run.call('UploadedFile#to_uint8_array preserves raw bytes') {
    # Build the 4-byte input with `.chr` — a Ruby source literal like
    # "\xDE\xAD\xBE\xEF" would be UTF-8-decoded by Opal at compile
    # time and the high bytes would collapse to U+FFFD before this
    # case ran (same workaround used in test/multipart_smoke.rb).
    bytes = 0xDE.chr + 0xAD.chr + 0xBE.chr + 0xEF.chr
    u = Cloudflare::UploadedFile.new(name: 'f', filename: 'a.bin', content_type: 'application/octet-stream', bytes_binstr: bytes)
    arr = u.to_uint8_array
    `#{arr}.length === 4 && #{arr}[0] === 0xDE && #{arr}[1] === 0xAD && #{arr}[2] === 0xBE && #{arr}[3] === 0xEF`
  }

  run.call('SSEStream frames data correctly') {
    # Use a TransformStream and inspect what Ruby writes to the writer.
    ts = `new TransformStream()`
    writer = `#{ts}.writable.getWriter()`
    out = Cloudflare::SSEOut.new(writer)
    out.event('hello', event: 'greet', id: '1')
    out.write("data: raw\n\n")
    out.close
    # Drain via a JS IIFE so Opal doesn't compile this into a
    # `loop do … __await__ … break` — which allocates a Promise per
    # iteration and blows up the workerd isolate under heavy load
    # (observed: V8 OOM after ~60s on /test/foundations).
    readable = `#{ts}.readable`
    decoded = `(async function(r){ var rd=r.getReader(); var d=new TextDecoder(); var out=''; while(true){ var c=await rd.read(); if(c.done) return out; out += d.decode(c.value); } })(#{readable})`.__await__
    decoded.include?('event: greet') &&
      decoded.include?('id: 1') &&
      decoded.include?('data: hello') &&
      decoded.include?('data: raw')
  }

  passed = cases.count { |c| c['pass'] }
  failed = cases.size - passed
  {
    'passed' => passed,
    'failed' => failed,
    'total'  => cases.size,
    'cases'  => cases
  }.to_json
end
# Phase 16 — self-hosted docs (Cloudflare-style /docs/*)
# Mustermann on Opal rejects `^`/`$` in regex routes. Trailing `/docs/` is normalized
# to `/docs` in Rack::Handler::Homura.build_rack_env (runtime gem).
docs_index_route = lambda do
  @title = 'ドキュメント — homura'
  @docs_page = 'index'
  @docs_section = :getting_started
  @docs_breadcrumb = [
    ['Docs', '/docs'],
    ['概要', nil]
  ]
  @docs_toc = [
    %w[hero このサイトについて],
    %w[gems 3つの gem],
    %w[next 次のステップ]
  ]
  @docs_inner = erb :docs_index
  erb :layout_docs
end
