# frozen_string_literal: true
# Route fragment 34 — api /api/chat/messages
post '/api/chat/messages' do
  content_type 'application/json'
  gate = ai_demos_block_or_nil
  next gate if gate
  # Inline JWT verification with dynamic algorithm detection.
  # authenticate_or_401 is the recommended safe API for fixed-algorithm
  # routes (see GET /api/chat/messages). This route uses inline
  # verification because it needs to detect the algorithm from the
  # token header (alg_from_token) to support multiple algorithms.
  auth_header = request.env['HTTP_AUTHORIZATION'].to_s
  parts = auth_header.split(' ', 2)
  if parts.length != 2 || parts[0].downcase != 'bearer'
    status 401
    next({ 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json)
  end
  auth_token = parts[1].strip
  if auth_token.empty?
    status 401
    next({ 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json)
  end
  # JWT verify may resolve asynchronously. If verification fails after
  # the await, return `[status, body]` directly so build_js_response
  # preserves the non-200 status instead of relying on post-await
  # `status 401`.
  begin
    JWT.decode(auth_token, settings.jwt_secret, true, algorithm: settings.jwt_algorithm)
  rescue JWT::ExpiredSignature
    next [401, { 'error' => 'unauthorized', 'reason' => 'token expired' }.to_json]
  rescue JWT::ImmatureSignature
    next [401, { 'error' => 'unauthorized', 'reason' => 'token not yet valid' }.to_json]
  rescue JWT::IncorrectAlgorithm
    next [401, { 'error' => 'unauthorized', 'reason' => 'algorithm mismatch' }.to_json]
  rescue JWT::VerificationError
    next [401, { 'error' => 'unauthorized', 'reason' => 'signature verification failed' }.to_json]
  rescue JWT::DecodeError => e
    next [401, { 'error' => 'unauthorized', 'reason' => "invalid token: #{e.message}" }.to_json]
  end
  bgate = ai_binding_block_or_nil
  next bgate if bgate

  body = parse_json_body
  session_id = normalize_session_id(body['session'])
  user_text  = body['content'].to_s
  if user_text.strip.empty?
    status 400
    next({ 'error' => 'content required' }.to_json)
  end

  requested_model = body['model'].to_s
  primary  = App::CHAT_MODELS[:primary]
  fallback = App::CHAT_MODELS[:fallback]
  # Allow either of the two configured models. Anything else is
  # rejected so a client can't run up neuron costs on arbitrary models.
  model = if requested_model == primary || requested_model == fallback
            requested_model
          else
            primary
          end

  # Helper methods that internally call `__await__` on a binding
  # (KV / D1 / AI) compile to async JS functions, so each helper
  # call must be `__await__`'d at the call site to unwrap the
  # returned Promise. Without the explicit await, `history` would
  # be a PromiseV2 and downstream `JSON.parse` / Array iteration
  # would crash with "undefined method `each` for PromiseV2".
  history = load_chat_history(session_id)
  messages = build_ai_messages(history, user_text)

  started_at = Time.now.to_f
  used_model = model
  used_fallback = false
  reply_text = nil
  ai_error  = nil

  begin
    result = Cloudflare::AI.run(
      model,
      # max_tokens raised to 1024 because OpenAI-style models (Gemma 4,
      # gpt-oss-*) report `finish_reason: "length"` and surface the
      # visible answer in `message.reasoning` instead of `content` when
      # truncated. 1024 is generous enough for most chat replies and
      # still well under Workers' 30s wall-time budget.
      { messages: messages, max_tokens: 1024 },
      binding: ai_binding
    )
    reply_text = App.extract_ai_text(result).strip
    raise Cloudflare::AIError.new('empty response', model: model) if reply_text.empty?
  rescue Cloudflare::AIError => e
    ai_error = e
  end

  # Fallback: if the primary model fails or returns empty, retry with
  # the secondary model exactly once before surfacing an error.
  if reply_text.nil? || reply_text.empty?
    used_fallback = true
    used_model = (model == primary) ? fallback : primary
    begin
      result = Cloudflare::AI.run(
        used_model,
        { messages: messages, max_tokens: 1024 },
        binding: ai_binding
      )
      reply_text = App.extract_ai_text(result).strip
    rescue Cloudflare::AIError => e
      status 502
      next({ 'error' => 'workers AI call failed', 'detail' => e.message, 'fallback_error' => true }.to_json)
    end
    if reply_text.nil? || reply_text.empty?
      status 502
      next({ 'error' => 'workers AI returned empty response on both primary and fallback' }.to_json)
    end
  end

  elapsed_ms = ((Time.now.to_f - started_at) * 1000).to_i
  new_history = history + [
    { 'role' => 'user',      'content' => user_text },
    { 'role' => 'assistant', 'content' => reply_text }
  ]
  save_chat_history(session_id, new_history)

  {
    'ok'           => true,
    'session'      => session_id,
    'model'        => used_model,
    'used_fallback'=> used_fallback,
    'elapsed_ms'   => elapsed_ms,
    'reply'        => reply_text,
    # Phase 11B follow-up: pre-rendered HTML so the client can
    # `innerHTML = reply_html` to show Markdown formatting (bullet
    # lists, bold, code fences, links). Safe to insert because
    # `HomurabiMarkdown.render` HTML-escapes the input first and
    # restricts link hrefs to http/https/mailto/relative.
    'reply_html'   => markdown_html(reply_text),
    'history_len'  => new_history.size
  }.to_json
end
