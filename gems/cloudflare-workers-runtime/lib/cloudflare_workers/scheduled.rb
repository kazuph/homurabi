# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 9 — Cloudflare Workers Cron Trigger dispatcher.
#
# Cloudflare Workers fire `scheduled(event, env, ctx)` for each entry
# in `wrangler.toml`'s `[triggers] crons = [...]` array. The runtime
# guarantees `event.cron` is one of the cron expressions declared in
# wrangler.toml; `event.scheduledTime` is the firing time as a JS
# epoch-millis number.
#
# This file:
#   1. Defines `Cloudflare::ScheduledEvent` — a Ruby wrapper around
#      the JS ScheduledEvent so user blocks see plain Ruby values
#      (`event.cron` -> String, `event.scheduled_time` -> Time).
#
#   2. Installs `globalThis.__HOMURABI_SCHEDULED_DISPATCH__` — the JS
#      hook called from `src/worker.mjs#scheduled`. The hook receives
#      the JS event/env/ctx, builds a Ruby ScheduledEvent, and calls
#      `Sinatra::Scheduled::ClassMethods#dispatch_scheduled` on the
#      Rack handler's app.
#
#   3. Exposes `Cloudflare::Scheduled.app=` so non-Sinatra Rack apps
#      can hook the dispatcher too. By default, `Rack::Handler::
#      CloudflareWorkers.app` (set by `run app` in user code) is used.
#
# Test entry point: `Cloudflare::Scheduled.dispatch(cron, scheduled_time, js_env, js_ctx)`
# — used by `test/scheduled_smoke.rb` so the same code path that the
# Workers runtime takes is exercised under Node, without needing the
# JS dispatcher.

require 'time'

module Cloudflare
  # Wrapper around the JS ScheduledEvent. The Workers runtime gives us:
  #
  #   event.cron          — String, e.g. '*/5 * * * *'
  #   event.scheduledTime — Number (millis-since-epoch)
  #   event.type          — String, always 'scheduled'
  #   event.waitUntil(p)  — same shape as ctx.waitUntil(p)
  #
  # We surface these as Ruby idioms so user code never needs backticks.
  class ScheduledEvent
    attr_reader :cron, :scheduled_time, :type, :raw

    def initialize(cron:, scheduled_time:, type: 'scheduled', raw: nil)
      @cron = cron.to_s.freeze
      @scheduled_time = scheduled_time
      @type = type.to_s.freeze
      @raw = raw
    end

    # Build a ScheduledEvent from the native JS event. `js_event` may
    # be nil during smoke tests; in that case the caller passes the
    # cron / scheduled_time via the keyword form above.
    #
    # JS undefined / null guards are written in JS land instead of
    # delegating to `nil?` because Opal doesn't always coerce a bare
    # JS undefined into Ruby's nil — calling `.nil?` on it raises
    # TypeError.
    def self.from_js(js_event)
      return new(cron: '', scheduled_time: Time.now) if `#{js_event} == null`

      cron      = `(#{js_event}.cron == null ? '' : String(#{js_event}.cron))`
      type      = `(#{js_event}.type == null ? 'scheduled' : String(#{js_event}.type))`
      has_sched = `(#{js_event}.scheduledTime != null)`
      sched_t   = if has_sched
                    sched_ms = `Number(#{js_event}.scheduledTime)`
                    Time.at(sched_ms.to_f / 1000.0)
                  else
                    Time.now
                  end

      new(cron: cron, scheduled_time: sched_t, type: type, raw: js_event)
    end

    def to_h
      {
        'cron'           => cron,
        'scheduled_time' => scheduled_time.to_i,
        'type'           => type
      }
    end
  end

  # Dispatcher singleton. The Rack handler installs the JS hook on
  # boot; user code never calls anything in this module directly.
  module Scheduled
    @app = nil

    class << self
      # Override the dispatch target. By default the dispatcher uses
      # `Rack::Handler::CloudflareWorkers.app`, which is whatever the
      # user passed to top-level `run app`. Tests use this to plug
      # a fake Sinatra subclass without booting the full handler.
      attr_accessor :app
    end

    # Install the JS-side dispatcher on globalThis. Idempotent — safe
    # to call multiple times (last writer wins).
    #
    # NOTE: kept as a single-line backtick x-string. Opal's parser
    # treats multi-line backtick strings as raw statements that don't
    # return a value AND it tries to lex-as-Ruby everything inside,
    # so JS comments containing the Ruby backtick delimiter (`...`)
    # crash the build. Single-line form sidesteps both pitfalls.
    def self.install_dispatcher
      mod = self
      `globalThis.__HOMURABI_SCHEDULED_DISPATCH__ = async function(js_event, js_env, js_ctx) { try { return await #{mod}.$dispatch_js(js_event, js_env, js_ctx); } catch (err) { try { globalThis.console.error('[Cloudflare::Scheduled] dispatch failed:', err && err.stack || err); } catch (e) {} return { error: String(err && err.message || err) }; } };(function(){var g=globalThis;g.__OPAL_WORKERS__=g.__OPAL_WORKERS__||{};g.__OPAL_WORKERS__.scheduled=g.__HOMURABI_SCHEDULED_DISPATCH__;})();`
    end

    # Called from the JS hook. Resolves the Ruby app, builds a
    # ScheduledEvent, runs `dispatch_scheduled` on the app class, and
    # returns the result Hash for diagnostics. We `__await__` the
    # inner dispatch so the returned object is the resolved Hash, not
    # a Promise — the JS hook then `await`s our return promise once.
    def self.dispatch_js(js_event, js_env, js_ctx)
      event = ScheduledEvent.from_js(js_event)
      target = resolve_app
      if target.nil?
        warn '[Cloudflare::Scheduled] no app registered; ignoring scheduled event'
        return { 'fired' => 0, 'total' => 0, 'results' => [], 'error' => 'no_app' }
      end
      target.dispatch_scheduled(event, js_env, js_ctx).__await__
    end

    # Test-friendly direct entry point. Lets `test/scheduled_smoke.rb`
    # exercise the same dispatch logic without going through the JS
    # hook. `cron` / `scheduled_time` are plain Ruby values. Returns
    # the awaited result Hash (callers can still `__await__` the
    # outer Promise — this method is async since it uses `__await__`).
    def self.dispatch(cron, scheduled_time = Time.now, js_env = nil, js_ctx = nil)
      event = ScheduledEvent.new(cron: cron, scheduled_time: scheduled_time)
      target = resolve_app
      raise 'no app registered for Cloudflare::Scheduled' if target.nil?
      target.dispatch_scheduled(event, js_env, js_ctx).__await__
    end

    # Await a JS Promise from inside `# await: true` code without
    # exposing the `__await__` keyword to callers. Re-throws Promise
    # rejections as synchronous Ruby exceptions so callers can rescue.
    # Sinatra::Scheduled uses this to bridge per-job exceptions out of
    # the async block boundary.
    #
    # Implemented as `__await__` directly so Opal compiles this method
    # itself as async — callers in `# await: true` files that do
    # `await_promise(p)` get the resolved value back the same way they
    # would from a bare `p.__await__`. Rejections re-throw as Ruby
    # exceptions thanks to ES8 `await`'s built-in throw semantics.
    def self.await_promise(promise)
      promise.__await__
    end

    # Resolve which app class should receive the dispatch. Priority:
    #   1. `Cloudflare::Scheduled.app = SomeApp`     (explicit override)
    #   2. `Rack::Handler::CloudflareWorkers.app`    (set by `run app`)
    # Returns the class itself (not an instance), because
    # `dispatch_scheduled` is a class method on Sinatra apps.
    def self.resolve_app
      candidate = @app
      if candidate.nil? && defined?(::Rack::Handler::CloudflareWorkers)
        candidate = ::Rack::Handler::CloudflareWorkers.app
      end
      return nil if candidate.nil?
      # Sinatra app classes respond to `dispatch_scheduled` (added by
      # Sinatra::Scheduled). Plain Rack apps would be instances and
      # lack the class method — we return them as-is and let the
      # caller's `dispatch_scheduled` raise NoMethodError so the
      # mistake is visible.
      if candidate.respond_to?(:dispatch_scheduled)
        candidate
      elsif candidate.respond_to?(:class) && candidate.class.respond_to?(:dispatch_scheduled)
        candidate.class
      else
        candidate
      end
    end
  end
end

# Auto-install the JS dispatcher hook the moment this file is loaded.
# Sinatra extensions are evaluated by the user code that comes after,
# so the hook must be live before the first scheduled event arrives.
Cloudflare::Scheduled.install_dispatcher
