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
# Phase 12 — Sequel (vendored v5.103.0) + D1 adapter (`sequel-d1` gem).
# `Sequel.connect(adapter: :d1, d1: …)` uses the per-request D1 binding
# from `env['cloudflare.DB']` (wired by cloudflare-workers-runtime), and Dataset DSL compiles
# to SQLite-dialect SQL which D1 speaks natively.
require 'sequel'

require_relative 'helpers/session_cookie'
require_relative 'helpers/chat_history'
require_relative 'helpers/debug_mail'
require_relative 'lib/debug_mail_controller'
require_relative 'helpers/markdown_render'

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
  # --- Cloudflare binding helpers (see app/helpers/chat_history.rb) ---
  helpers Homurabi::CloudflareBindingHelpers
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

  helpers Homurabi::JwtKeyHelpers

  # ------------------------------------------------------------------
  # Phase 9 — Cron Trigger handlers (see also /test/scheduled* routes).
  # ------------------------------------------------------------------
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

  # Workers AI response shaping lives in `Homurabi::ChatHistoryClassMethods#extract_ai_text`.
  extend Homurabi::ChatHistoryClassMethods
  helpers Homurabi::ChatHistoryHelpers
  helpers Homurabi::MarkdownRenderHelpers

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

  # Phase 17 — production /debug/mail gate (session username must match).
  DEBUG_MAIL_ADMIN_USERNAME = 'kazuph'

  include Homurabi::SessionCookieInstanceMethods
  helpers Homurabi::DebugMailHelpers

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
  #
  # Routes are inlined into `build/routes_app_class_eval.rb` (App.class_eval)
  # by `bin/inline-routes-for-opal` before Opal compile — plain `require` of
  # route files would register on main, not App. Source: canonical_all.rb.
  require 'routes_app_class_eval'
end

run App
