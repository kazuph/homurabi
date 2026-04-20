# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
#
# A plain Sinatra application. Ported as faithfully as possible from
# the canonical Sinatra README / examples, so every line here reads
# the same as it would in any other Sinatra project. Nothing about
# Cloudflare Workers, Opal, or the Cloudflare bindings is visible in
# this file — the adapter lives entirely in `lib/cloudflare_workers.rb`.
#
# HTML pages go through real ERB templates stored under `views/*.erb`
# and rendered with the classic `erb :name` helper. homurabi's build
# pipeline precompiles those templates with `bin/compile-erb` so the
# Workers sandbox never has to call `eval` / `new Function` at runtime.

require 'json'
require 'time'
require 'sinatra/cloudflare_workers'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'base64'
require 'jwt'
require 'homurabi_markdown'
# Phase 11A — HTTP foundations. `faraday` is the compat shim living
# under vendor/ (NOT the real ruby-faraday gem — see file header for
# the rationale). The Cloudflare::Multipart parser and the SSEStream
# helper are auto-required from lib/cloudflare_workers.rb.
require 'faraday'
# Phase 12 — Sequel (vendored v5.103.0) + D1 adapter. `Sequel.connect('d1://')`
# resolves the D1 binding from Cloudflare::Bindings.current (wired
# per-request by lib/cloudflare_workers.rb), and Dataset DSL compiles
# to SQLite-dialect SQL which D1 speaks natively.
require 'sequel'

class App < Sinatra::Base
  # Phase 8 — JWT auth. The secret is the default HS256 path; asymmetric
  # algo demos generate their own keys on first use and cache them in
  # Ruby class variables (`@@rsa_key`, `@@ec256_key`, …) so repeat
  # requests don't pay the 2048-bit RSA generation cost. The secret is
  # deterministic only for local dev — in production it should come
  # from a Workers secret (wrangler secret put JWT_SECRET) pulled via
  # `env['cloudflare.env'].JWT_SECRET`.
  register Sinatra::JwtAuth
  set :jwt_secret, 'homurabi-phase8-demo-secret-change-me-in-prod'
  set :jwt_algorithm, 'HS256'
  # Phase 9 — Cron Trigger DSL. Use `schedule '*/5 * * * *' do ... end`
  # below; matching jobs are dispatched from `src/worker.mjs#scheduled`
  # via `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`.
  register Sinatra::Scheduled
  # Phase 11A — SSE / streaming helper. Exposes `sse do |out| ... end`
  # on every route (returns a `Cloudflare::SSEStream` which
  # `build_js_response` pipes into `new Response(readable)`).
  register Sinatra::Streaming
  # Phase 11B — Sinatra::Queue. Adds the `consume_queue 'name' do
  # |batch| ... end` DSL so queue consumer handlers live next to the
  # HTTP routes.
  register Sinatra::Queue
  # --- Cloudflare binding helpers ------------------------------------
  # These let routes access D1/KV/R2 with the same brevity as
  # ActiveRecord's `User.find(id)` pattern, without introducing an ORM.
  helpers do
    def db;     env['cloudflare.DB'];     end
    def kv;     env['cloudflare.KV'];     end
    def bucket; env['cloudflare.BUCKET']; end

    # Crypto demo / self-test routes generate fresh RSA keys + run
    # PBKDF2 per call. Leaving them publicly reachable in production
    # is a CPU-DoS vector. Gate behind the wrangler [vars] flag
    # `HOMURABI_ENABLE_CRYPTO_DEMOS`. Default-deny everywhere.
    def crypto_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_CRYPTO_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 9 — gate for the scheduled introspection / manual-fire
    # routes. `/test/scheduled/run` writes to D1 + KV without auth, so
    # leaving it open in production lets any caller burn binding quota.
    # Default OFF; flip via wrangler [vars] HOMURABI_ENABLE_SCHEDULED_DEMOS=1.
    def scheduled_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 11B — gate for the Durable Object / Cache API / Queues
    # demo routes (`/demo/do*`, `/demo/cache*`, `/api/enqueue`,
    # `/test/bindings`). Each demo writes to DO storage or enqueues
    # a message on every request, so leaving them publicly reachable
    # in production burns metered quota. Default OFF; flip via
    # wrangler [vars] HOMURABI_ENABLE_BINDING_DEMOS=1 in dev.
    def binding_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_BINDING_DEMOS) || ''`
      val.to_s == '1'
    end

    # Phase 11B — Sinatra helpers around the DO / Cache / Queue
    # wrappers. They mirror the `db` / `kv` / `bucket` pattern so
    # routes can call them without touching JS.

    # Wrapped DurableObjectNamespace for the `COUNTER` binding.
    # nil when no binding is attached (e.g. in tests or missing
    # wrangler.toml entry).
    def do_counter
      env['cloudflare.DO_COUNTER']
    end

    # Default edge cache.  A thin wrapper over `caches.default`.
    def cache
      @cache ||= ::Cloudflare::Cache.default
    end

    # The `JOBS_QUEUE` producer binding. nil when the binding is
    # not attached.
    def jobs_queue
      env['cloudflare.QUEUE_JOBS']
    end

    # The `JOBS_DLQ` dead-letter-queue producer. Routes can post to
    # this directly when the caller already knows a message should not
    # go through the main retry loop.
    def jobs_dlq
      env['cloudflare.QUEUE_JOBS_DLQ']
    end

    # Serve an expensive computation through Cache API. On a cache
    # hit the cached Response body is returned; on a miss the block
    # is evaluated, the result is stored with the given TTL, and
    # the fresh body is returned.
    #
    #   get '/demo/cache/heavy' do
    #     content_type 'application/json'
    #     cache_get(request.url, ttl: 60) { expensive_json }
    #   end
    #
    # Headers picked up from the route's `content_type` call are
    # copied onto the stored Response so a cache hit echoes the
    # same content-type — otherwise the browser would see a plain
    # 200 with no content-type and try to sniff.
    #
    # NOTE: the Workers Cache API (and miniflare's local emulation)
    # requires the cache-key URL to be http/https AND the stored
    # Response to have a `Date` + `Cache-Control: max-age > 0` header.
    # A missing `Date` header is the most common reason a put
    # silently stores nothing — we populate it here so routes don't
    # have to know.
    def cache_get(cache_key, ttl: 60, content_type_override: nil, &block)
      # Copilot review PR #9: fail loudly when no block is given
      # instead of NoMethodError on nil.call later. Same pattern
      # `consume_queue` / `DurableObject.define` use at registration
      # time.
      raise ArgumentError, 'cache_get requires a block' unless block
      # Copilot review PR #9 (additional): the Workers Cache API
      # silently refuses to store a Response whose Cache-Control
      # max-age is 0 or negative, so a caller asking for `ttl: 0` or
      # a bad `params['ttl']` would compute the body, skip storage,
      # and still claim it was cached. Make the contract explicit:
      # ttl must be a positive integer; clamp to at least 1 second to
      # protect the cache from being poisoned with unstorable entries.
      cache_ttl = ttl.to_i
      if cache_ttl <= 0
        raise ArgumentError, "cache_get ttl must be > 0 (got #{ttl.inspect}); Workers refuses to store max-age=0"
      end
      c = cache
      cached = c.match(cache_key).__await__
      if cached
        # Replay the cached headers so the outer Rack response
        # matches what we originally put in (content-type etc.).
        cached.headers.each { |k, v| response.headers[k] = v }
        response.headers['x-homurabi-cache'] = 'HIT'
        return cached.body
      end
      body = block.call
      ct = content_type_override || response['Content-Type'] || 'text/plain; charset=utf-8'
      c.put(
        cache_key, body,
        status: 200,
        headers: {
          'content-type'     => ct,
          'cache-control'    => "public, max-age=#{cache_ttl}",
          'date'             => Time.now.httpdate,
          'x-homurabi-cache' => 'MISS'
        }
      ).__await__
      response.headers['x-homurabi-cache'] = 'MISS'
      body
    end
  end
  # ------------------------------------------------------------------
  # HTML pages — each route sets a few `@ivars` then renders an ERB
  # template from `views/`. Exactly like Sinatra's README example:
  #
  #     get '/' do
  #       erb :index
  #     end
  # ------------------------------------------------------------------

  JWT_ACCESS_TTL  = 3600          # 1 hour
  JWT_REFRESH_TTL = 86_400 * 30   # 30 days

  helpers do
    # Returns the signing key + verification key pair for the given alg.
    # Keys are lazily generated and cached on the App class so repeat
    # requests skip the 2048-bit RSA generation.
    def jwt_keys_for(alg)
      case alg
      when 'HS256', 'HS384', 'HS512'
        [settings.jwt_secret, settings.jwt_secret]
      when 'RS256', 'RS384', 'RS512', 'PS256', 'PS384', 'PS512'
        App.class_variable_set(:@@rsa_key, OpenSSL::PKey::RSA.new(2048)) unless App.class_variable_defined?(:@@rsa_key)
        rsa = App.class_variable_get(:@@rsa_key)
        [rsa, rsa.public_key]
      when 'ES256'
        App.class_variable_set(:@@ec256_key, OpenSSL::PKey::EC.generate('prime256v1')) unless App.class_variable_defined?(:@@ec256_key)
        ec = App.class_variable_get(:@@ec256_key)
        [ec, ec]
      when 'ES384'
        App.class_variable_set(:@@ec384_key, OpenSSL::PKey::EC.generate('secp384r1')) unless App.class_variable_defined?(:@@ec384_key)
        ec = App.class_variable_get(:@@ec384_key)
        [ec, ec]
      when 'ES512'
        App.class_variable_set(:@@ec521_key, OpenSSL::PKey::EC.generate('secp521r1')) unless App.class_variable_defined?(:@@ec521_key)
        ec = App.class_variable_get(:@@ec521_key)
        [ec, ec]
      when 'EdDSA', 'ED25519'
        App.class_variable_set(:@@ed_key, OpenSSL::PKey::Ed25519.generate) unless App.class_variable_defined?(:@@ed_key)
        ed = App.class_variable_get(:@@ed_key)
        [ed, ed]
      else
        raise ArgumentError, "unsupported alg: #{alg.inspect}"
      end
    end

    # Inspect a JWT header without verifying so we can pick the right
    # verification key. Safe to do because we always re-verify the
    # signature with the detected alg.
    def alg_from_token(token)
      header_seg = token.to_s.split('.').first.to_s
      padded     = header_seg + ('=' * ((4 - header_seg.length % 4) % 4))
      json       = Base64.urlsafe_decode64(padded)
      JSON.parse(json)['alg']
    rescue StandardError
      nil
    end
  end

  # POST /api/login — issues access + refresh tokens.
  # Body (JSON): { "username": "..." }
  # Query: ?alg=HS256|RS256|PS256|ES256|ES384|ES512|EdDSA (default HS256)
  schedule '*/5 * * * *', name: 'heartbeat' do |event|
    cf_env = env['cloudflare.env']
    enabled = cf_env && `(#{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS || '')`.to_s == '1'
    next unless enabled
    # Insert one row into D1's heartbeats table per cron firing.
    # Falls back to a no-op when DB is not bound (test envs).
    if db
      db.execute_insert(
        'INSERT INTO heartbeats (cron, scheduled_at, fired_at, note) VALUES (?, ?, ?, ?)',
        [event.cron, event.scheduled_time.to_i, Time.now.to_i, 'phase9-heartbeat']
      )
    end
  end

  schedule '0 */1 * * *', name: 'hourly-housekeeping' do |event|
    cf_env = env['cloudflare.env']
    enabled = cf_env && `(#{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS || '')`.to_s == '1'
    next unless enabled
    # Demo: bump a KV counter so we can prove hourly cron runs from
    # outside a test by inspecting `/kv/cron:hourly-counter` over HTTP.
    # Falls back to a no-op when KV is not bound (test envs).
    if kv
      raw  = kv.get('cron:hourly-counter').__await__
      prev = 0
      if raw
        begin
          prev = JSON.parse(raw)['count'].to_i
        rescue StandardError
          prev = 0
        end
      end
      payload = {
        'count'        => prev + 1,
        'last_cron'    => event.cron,
        'last_run_at'  => Time.now.to_i,
        'last_sched_t' => event.scheduled_time.to_i
      }.to_json
      kv.put('cron:hourly-counter', payload).__await__
    end
  end

  # ------------------------------------------------------------------
  # Phase 9 self-test endpoints — gated on HOMURABI_ENABLE_SCHEDULED_DEMOS.
  #
  # GET  /test/scheduled            → list every registered job (cron,
  #                                    name, source location)
  # POST /test/scheduled/run?cron=… → manually fire every job whose
  #                                    cron expression equals the
  #                                    query param. Same code path the
  #                                    Workers runtime takes; lets us
  #                                    smoke-test cron handlers from
  #                                    a curl in `wrangler dev`
  #                                    without waiting 5 minutes.
  # ------------------------------------------------------------------
  CHAT_MODELS = {
    primary:  '@cf/google/gemma-4-26b-a4b-it',
    fallback: '@cf/openai/gpt-oss-120b'
  }.freeze
  CHAT_HISTORY_LIMIT = 32       # last N messages kept in KV per session
  CHAT_HISTORY_TTL   = 86_400 * 7  # 1 week
  CHAT_SYSTEM_PROMPT = 'You are homurabi, a friendly Sinatra-on-Cloudflare-Workers assistant. Reply concisely. If the user writes Japanese, reply in Japanese. If the user writes English, reply in English.'

  # Workers AI returns one of two response shapes depending on the model:
  # 1. legacy `{ response: "..." }`            (e.g. older llama, mistral)
  # 2. OpenAI-style `{ choices: [{ message: { content: "..." } }] }`
  #    (Gemma 4, gpt-oss-* and any other "chat completions"-shaped model)
  # Helper that tolerates both so the route doesn't have to branch.
  def self.extract_ai_text(out)
    return out.to_s unless out.is_a?(Hash)
    # OpenAI-style choices[].message.content
    if out['choices'].is_a?(Array) && !out['choices'].empty?
      msg = out['choices'][0].is_a?(Hash) ? out['choices'][0]['message'] : nil
      if msg.is_a?(Hash)
        c = msg['content']
        return c.to_s if c.is_a?(String) && !c.empty?
        # Some models put the visible answer in `reasoning` when the
        # response is truncated by max_tokens. Surface it as a fallback
        # so the user still sees something useful.
        r = msg['reasoning']
        return r.to_s if r.is_a?(String) && !r.empty?
      end
    end
    # Legacy `{ response: "..." }` / generic fallbacks.
    %w[response result output text].each do |k|
      v = out[k]
      return v.to_s if v.is_a?(String) && !v.empty?
    end
    ''
  end

  helpers do
    def ai_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_AI_DEMOS) || ''`
      val.to_s == '1'
    end

    def ai_binding
      env['cloudflare.AI']
    end

    # JS-aware "is the binding present?" — env.AI is a raw JS object
    # without a Ruby `.nil?` method, so `binding.nil?` would explode at
    # runtime. This helper checks the JS-level null/undefined directly.
    def ai_binding?
      v = env['cloudflare.AI']
      `(#{v} != null)`
    end

    # JSON body parse with a graceful default.
    def parse_json_body
      raw = request.body.read.to_s
      return {} if raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError, StandardError
      {}
    end

    # Allow only `[A-Za-z0-9_-]{1,64}` for session ids so a crafted
    # `?session=` cannot inject HTML when echoed back to /chat, cannot
    # generate exotic KV key names (which would also escape `chat:` and
    # collide with other namespaces), and cannot create unbounded
    # per-user key cardinality. Falls back to `'demo'` on rejection.
    SESSION_ID_RE = /\A[A-Za-z0-9_-]{1,64}\z/.freeze

    def normalize_session_id(raw)
      s = raw.to_s
      return 'demo' if s.empty?
      SESSION_ID_RE.match?(s) ? s : 'demo'
    end

    def chat_kv_key(session_id)
      "chat:#{session_id}"
    end

    # Returns the array of {role, content} message Hashes for a session,
    # or [] if KV has nothing (or no KV is bound).
    def load_chat_history(session_id)
      return [] unless kv
      raw = kv.get(chat_kv_key(session_id)).__await__
      return [] if raw.nil? || raw.empty?
      arr = JSON.parse(raw)
      arr.is_a?(Array) ? arr : []
    rescue JSON::ParserError
      []
    end

    def save_chat_history(session_id, history)
      return unless kv
      trimmed = history.last(CHAT_HISTORY_LIMIT)
      # Pass CHAT_HISTORY_TTL through so KV expires the entry
      # automatically and the namespace doesn't accumulate dead
      # sessions forever (the constant was previously documented but
      # unused — Copilot review #5).
      kv.put(chat_kv_key(session_id), trimmed.to_json, expiration_ttl: CHAT_HISTORY_TTL).__await__
    end

    def clear_chat_history(session_id)
      return unless kv
      kv.delete(chat_kv_key(session_id)).__await__
    end

    # Convert chat history to the messages array Workers AI expects.
    # Always prepends a system prompt so the model has consistent persona.
    def build_ai_messages(history, latest_user_text)
      msgs = [{ 'role' => 'system', 'content' => CHAT_SYSTEM_PROMPT }]
      history.each { |m| msgs << { 'role' => m['role'], 'content' => m['content'] } }
      msgs << { 'role' => 'user', 'content' => latest_user_text }
      msgs
    end

    # Both gates return either nil (= keep going) or a `[status, body]`
    # tuple that the caller hands back via `next`. We deliberately do
    # NOT use `halt` because the chat routes are `# await: true` async
    # blocks; `halt` is implemented as `throw :halt`, and the throw
    # escapes Sinatra's synchronous `catch :halt` wrapper through the
    # async/await boundary (Copilot review #8/#9). Same root cause as
    # the JWT auth helper rewrite.
    def ai_demos_block_or_nil
      return nil if ai_demos_enabled?
      [404, { 'error' => 'AI demos disabled (set HOMURABI_ENABLE_AI_DEMOS=1 in wrangler vars)' }.to_json]
    end

    def ai_binding_block_or_nil
      return nil if ai_binding?
      [503, { 'error' => 'AI binding not configured (wrangler.toml [ai] block missing or wrangler version too old)' }.to_json]
    end

    # Inline JWT verification tailored for the chat routes.
    #
    # Sinatra's `Sinatra::JwtAuth#authenticate!` helper relies on `halt`,
    # which is implemented via `throw :halt`. When the helper itself is
    # `# await: true` (because JWT.decode awaits Web Crypto subtle), the
    # `throw` escapes the async boundary before Sinatra's
    # `catch :halt do ... end` wrapper can see it, and the route crashes
    # with `UncaughtThrowError: "halt"`. Same root cause as the
    # `each: undefined method for PromiseV2` issue — async Sinatra needs
    # values, not control-flow exceptions, across the await boundary.
    #
    # `chat_verify_token!` returns either:
    #   - a Hash with `{ ok: true, payload: <decoded> }` on success, or
    #   - a Hash with `{ ok: false, status: 401, body: <json> }` on
    #     failure (so the route can `next body` after a status set).
    # The route is responsible for halting / returning early.
    def chat_verify_token!
      header = request.env['HTTP_AUTHORIZATION'].to_s
      parts = header.split(' ', 2)
      if parts.length != 2 || parts[0].downcase != 'bearer'
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      token = parts[1].strip
      if token.empty?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      verify_key = settings.jwt_secret
      algorithm  = settings.jwt_algorithm
      reason = nil
      decoded = begin
        JWT.decode(token, verify_key, true, algorithm: algorithm)
      rescue JWT::ExpiredSignature
        reason = 'token expired'
        nil
      rescue JWT::VerificationError
        reason = 'signature verification failed'
        nil
      rescue JWT::IncorrectAlgorithm
        reason = 'algorithm mismatch'
        nil
      rescue JWT::DecodeError => e
        reason = "invalid token: #{e.message}"
        nil
      rescue StandardError => e
        reason = "auth error: #{e.message}"
        nil
      end
      if decoded.nil?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => reason || 'token verification failed' }.to_json }
      end
      payload, _header = decoded
      @jwt_payload = payload
      { 'ok' => true, 'payload' => payload }
    end
  end

  # ----------------------------------------------------------------
  # Phase 13 follow-up — cookie-based session login.
  # Browser flow: /login form → POST /login → set homurabi_session
  # cookie (base64url `username:exp` payload with HMAC-SHA256
  # signature) → redirect to /chat. Guards /chat so only
  # logged-in users can reach the AI page.
  # ----------------------------------------------------------------

  # Custom HMAC-SHA256 signed cookie helpers (sync, with a
  # base64url-encoded `username:exp` payload — not a JWT). Going
  # custom avoids JWT.encode's auto-awaited Promise path, which
  # collides with Sinatra `redirect`'s :halt throw across Opal's
  # async boundary. Constants stay at top level rather than inside
  # `helpers do ... end` so startup cost stays minimal — the
  # previous `helpers` block form pushed the Cloudflare deploy
  # startup past its CPU budget (code 10021).
  SESSION_COOKIE_TTL  = 86_400
  SESSION_COOKIE_NAME = 'homurabi_session'

  def verify_session_cookie(raw)
    return nil unless raw.is_a?(String) && raw.include?('.')
    payload, sig = raw.split('.', 2)
    return nil if payload.nil? || sig.nil? || payload.empty? || sig.empty?
    expected = OpenSSL::HMAC.hexdigest('SHA256', settings.jwt_secret, payload)
    return nil unless Rack::Utils.secure_compare(expected, sig)
    decoded = Base64.urlsafe_decode64(payload) rescue nil
    return nil if decoded.nil?
    username, exp = decoded.split(':', 2)
    return nil if username.nil? || exp.nil?
    return nil if Time.now.to_i > exp.to_i
    username
  end

  def mint_session_cookie(username)
    exp = Time.now.to_i + SESSION_COOKIE_TTL
    payload = Base64.urlsafe_encode64("#{username}:#{exp}", padding: false)
    sig = OpenSSL::HMAC.hexdigest('SHA256', settings.jwt_secret, payload)
    "#{payload}.#{sig}"
  end

  def current_session_user
    verify_session_cookie(request.cookies[SESSION_COOKIE_NAME].to_s)
  end

  # GET /login — simple demo login form. Any non-empty username
  # mints an HMAC-signed session cookie carrying `username:exp`.
  # No password check — this is a demo of the signed-cookie
  # session flow, not an identity provider.
  consume_queue 'homurabi-jobs-dlq' do |batch|
    if kv
      msgs = batch.messages
      i = 0
      while i < msgs.length
        msg = msgs[i]
        record = {
          'id'           => msg.id,
          'body'         => msg.body,
          'from_queue'   => batch.queue,
          'dead_at'      => Time.now.to_i,
          'batch_index'  => i
        }
        kv.put("queue:dlq:#{i}", record.to_json, expiration_ttl: 86_400).__await__
        msg.ack
        i += 1
      end
    else
      batch.ack_all
    end
    batch.size
  end

  consume_queue 'homurabi-jobs' do |batch|
    # Under `# await: true`, using `Array#each` with an internal
    # `__await__` is unreliable because Opal yields to an async
    # callback whose return value is never awaited by `each` — some
    # writes silently drop. Use an indexed `while` loop instead, the
    # same pattern `Sinatra::Scheduled#dispatch_scheduled` adopts.
    if kv
      msgs = batch.messages
      i = 0
      total = msgs.length
      while i < total
        msg = msgs[i]
        body_hash = msg.body.is_a?(Hash) ? msg.body : {}
        # Test hook: messages with `"fail": true` are retried so the
        # Workers runtime eventually routes them into the DLQ after
        # exhausting `max_retries`. Exists so
        # `GET /demo/queue/dlq-status` can observe a live DLQ flow in
        # `wrangler dev` without a real failing job.
        if body_hash['fail'] == true
          msg.retry
        else
          record = {
            'id'           => msg.id,
            'body'         => msg.body,
            'queue'        => batch.queue,
            'consumed_at'  => Time.now.to_i,
            'batch_index'  => i
          }
          kv.put("queue:last-consumed:#{i}", record.to_json, expiration_ttl: 86_400).__await__
          msg.ack
        end
        i += 1
      end
    else
      batch.ack_all
    end
    batch.size
  end

  # Phase 11B — WebSocket handlers for HomurabiCounterDO. The DO
  # echoes any text frame back prefixed with "echo:" AND atomically
  # bumps the counter per received frame so clients can observe the
  # hibernation-aware storage writes. Uses state.storage (same path
  # that HTTP /inc uses) so `wrangler dev` + `/demo/do?action=peek`
  # sees the increments after a WebSocket session.
  Cloudflare::DurableObject.define_web_socket_handlers('HomurabiCounterDO',
    on_message: ->(ws, message, state) {
      text = `typeof #{message} === 'string' ? #{message} : (typeof Buffer !== 'undefined' && Buffer.isBuffer(#{message}) ? #{message}.toString('utf8') : '')`
      # Fire-and-forget the storage increment inside the async IIFE
      # so the ws.send is not blocked by the round-trip. We pass the
      # JS state into a single-line async fn to avoid the multi-line
      # x-string quirk documented elsewhere.
      js_state_raw = state.js_state
      `(async function(ws, state, text) { try { var prev = (await state.storage.get('count')) || 0; var next = (typeof prev === 'number' ? prev : parseInt(prev, 10) || 0) + 1; await state.storage.put('count', next); ws.send('echo:' + text + ' count=' + next); } catch (e) { try { ws.send('error: ' + String(e && e.message || e)); } catch (_) {} } })(#{ws}, #{js_state_raw}, #{text})`
      nil
    },
    on_close: ->(ws, code, reason, _clean, _state) {
      # Mirror the close back to the client so both sides agree on
      # the shutdown code. Hibernation API requires an explicit
      # server-side close call.
      c = code.to_i
      r = reason.to_s
      `(function(ws, c, r) { try { ws.close(c, r); } catch (_) {} })(#{ws}, #{c}, #{r})`
      nil
    },
    on_error: ->(ws, err, _state) {
      # Just log the error — nothing meaningful to do beyond record it.
      `try { globalThis.console.error('[HomurabiCounterDO.ws] error:', #{err}); } catch (_) {}`
      nil
    }
  )

  # GET /demo/do/ws — upgrades to a WebSocket routed into the DO.
  # The DO's Hibernation handlers echo every frame back with
  # "echo:<text> count=<n>" where <n> is the shared counter, so a
  # single WS session also increments the same counter that
  # `/demo/do?action=peek` reads from over HTTP.
  Cloudflare::DurableObject.define('HomurabiCounterDO') do |state, request|
    path = request.path
    prev = (state.storage.get('count').__await__ || 0).to_i
    if path.end_with?('/inc')
      next_count = prev + 1
      state.storage.put('count', next_count).__await__
      [
        200,
        { 'content-type' => 'application/json' },
        {
          'count'       => next_count,
          'previous'    => prev,
          'path'        => path,
          'do_id'       => state.id,
          'updated_at'  => Time.now.to_i
        }.to_json
      ]
    elsif path.end_with?('/reset')
      state.storage.delete('count').__await__
      [
        200,
        { 'content-type' => 'application/json' },
        { 'reset' => true, 'do_id' => state.id }.to_json
      ]
    else
      [
        200,
        { 'content-type' => 'application/json' },
        { 'count' => prev, 'path' => path, 'do_id' => state.id }.to_json
      ]
    end
  end

  # GET /demo/do — hit the Counter DO by name. The `name` query param
  # (default 'global') selects which DO instance to address.
  helpers do
    # Phase 11A gate — same default-off pattern as /test/crypto / /test/ai.
    # /test/foundations hammers an external URL (ipify) and writes to R2,
    # so leaving it publicly reachable in production is a small but real
    # abuse vector. Flip via wrangler [vars] HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1.
    def foundations_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_FOUNDATIONS_DEMOS) || ''`
      val.to_s == '1'
    end
  end

  # GET /demo/faraday — hit a public JSON API through Faraday + the
  # bundled :json middleware. Proves the Faraday shim can stand in for
  # the real gem for the usual "talk to a REST API" pattern.
  #
  # Gated on HOMURABI_ENABLE_FOUNDATIONS_DEMOS (default deny) because
  # the route makes outbound calls to an external service and shouldn't
  # be reachable by anonymous traffic in production.
  require_relative 'routes/bootstrap'
end

run App
