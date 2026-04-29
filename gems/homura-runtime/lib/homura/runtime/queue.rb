# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Cloudflare Queues binding wrapper.
#
# Cloudflare Queues let a Worker send messages to a persistent queue
# and another Worker (or the same one) consume them in batches.
#
#   Producer side:
#     env.JOBS_QUEUE.send(body, options)
#     env.JOBS_QUEUE.sendBatch(messages, options)
#
#   Consumer side (worker.mjs):
#     export default { async queue(batch, env, ctx) { ... } }
#     // batch.messages[i].body           — the payload
#     // batch.messages[i].ack()          — per-message ack
#     // batch.messages[i].retry()        — retry with backoff
#     // batch.ackAll() / batch.retryAll()
#
# This file provides:
#
#   1. `Cloudflare::Queue` — a Ruby wrapper around the producer binding
#      (`env.JOBS_QUEUE`). `#send(body, delay_seconds:, content_type:)`
#      and `#send_batch(messages)` return JS Promises.
#
#   2. `Cloudflare::QueueBatch` / `Cloudflare::QueueMessage` — Ruby
#      views over the JS batch passed to the `queue()` export. Each
#      message exposes `.body` (parsed if JSON), `.id`, `.timestamp`,
#      `.ack` / `.retry`.
#
#   3. A dispatcher hook (`globalThis.__HOMURA_QUEUE_DISPATCH__`)
#      that `src/worker.mjs#queue` calls once per incoming batch. It
#      walks `App.consume_queue_handlers` (registered via the
#      `consume_queue 'queue-name' do |batch| ... end` DSL in
#      lib/sinatra/queue.rb) and invokes whichever matches the batch's
#      `queue` name.

require 'json'

module Cloudflare
  class QueueError < StandardError
    attr_reader :operation, :queue
    def initialize(message, operation: nil, queue: nil)
      @operation = operation
      @queue = queue
      super("[Cloudflare::Queue] queue=#{queue || '?'} op=#{operation || 'send'}: #{message}")
    end
  end

  # Producer wrapper. The binding's JS API:
  #   env.JOBS_QUEUE.send(body, options?)            — one message
  #   env.JOBS_QUEUE.sendBatch(messages, options?)   — multiple
  # Each returns a JS Promise resolving to undefined.
  class Queue
    attr_reader :js, :name

    def initialize(js, name = nil)
      @js = js
      @name = (name || 'queue').to_s
    end

    def available?
      js = @js
      # Opal's Ruby nil is a runtime sentinel (Opal.nil), not JS null.
      # See `lib/homura/runtime/cache.rb#available?` for the same
      # pattern and rationale.
      !!`(#{js} !== null && #{js} !== undefined && #{js} !== Opal.nil)`
    end

    # Send one message. `body` may be any JSON-serialisable Ruby value.
    # Strings / numbers / booleans pass through; Hashes / Arrays are
    # sent as plain JS objects (Workers Queues natively encodes them
    # via structured clone).
    #
    #   delay_seconds: 60   # schedule for ~1 minute from now
    #   content_type: "json" (default) | "text" | "bytes"
    def send(body, delay_seconds: nil, content_type: nil)
      js = @js
      qname = @name
      err_klass = Cloudflare::QueueError
      raise QueueError.new('queue binding not bound', operation: 'send', queue: qname) unless available?

      js_body = ruby_to_js(body)
      js_opts = `({})`
      `#{js_opts}.delaySeconds = #{delay_seconds.to_i}` if delay_seconds
      `#{js_opts}.contentType  = #{content_type.to_s}`  if content_type

      # Single-line IIFE — see `lib/homura/runtime/cache.rb#put`
      # for the Opal multi-line x-string quirk. Passing arguments in
      # explicitly (rather than interpolating inside the template)
      # keeps the Promise a first-class expression.
      `(async function(js, body, opts, qname, Kernel, err_klass) { try { await js.send(body, opts); } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'send', queue: qname }))); } return null; })(#{js}, #{js_body}, #{js_opts}, #{qname}, #{Kernel}, #{err_klass})`
    end

    # Send an Array of {body:, delay_seconds?, content_type?} Hashes
    # or plain bodies as a single batch.
    def send_batch(messages, delay_seconds: nil)
      js = @js
      qname = @name
      err_klass = Cloudflare::QueueError
      raise QueueError.new('queue binding not bound', operation: 'send_batch', queue: qname) unless available?

      js_msgs = `([])`
      messages.each do |m|
        if m.is_a?(Hash)
          body = m['body'] || m[:body]
          ct   = m['content_type'] || m[:content_type]
          ds   = m['delay_seconds'] || m[:delay_seconds]
          js_body = ruby_to_js(body)
          js_msg = `({ body: #{js_body} })`
          `#{js_msg}.contentType  = #{ct.to_s}` if ct
          `#{js_msg}.delaySeconds = #{ds.to_i}` if ds
          `#{js_msgs}.push(#{js_msg})`
        else
          js_body = ruby_to_js(m)
          `#{js_msgs}.push({ body: #{js_body} })`
        end
      end
      js_opts = `({})`
      `#{js_opts}.delaySeconds = #{delay_seconds.to_i}` if delay_seconds

      # Single-line IIFE — see `send` above for rationale.
      `(async function(js, msgs, opts, qname, Kernel, err_klass) { try { await js.sendBatch(msgs, opts); } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'send_batch', queue: qname }))); } return null; })(#{js}, #{js_msgs}, #{js_opts}, #{qname}, #{Kernel}, #{err_klass})`
    end

    private

    # Same Ruby→JS conversion that Cloudflare::AI.ruby_to_js uses, but
    # local to avoid cross-wrapper coupling.
    def ruby_to_js(val)
      return val if val.is_a?(String) || val.is_a?(Numeric) || val == true || val == false || val.nil?
      if val.is_a?(Symbol)
        return val.to_s
      end
      if val.is_a?(Hash)
        obj = `({})`
        val.each do |k, v|
          ks = k.to_s
          jv = ruby_to_js(v)
          `#{obj}[#{ks}] = #{jv}`
        end
        return obj
      end
      if val.is_a?(Array)
        arr = `([])`
        val.each { |v| jv = ruby_to_js(v); `#{arr}.push(#{jv})` }
        return arr
      end
      val
    end
  end

  # Represents one message inside a queue batch. Wraps the JS message
  # object so user code can call `.body`, `.id`, `.ack`, `.retry`.
  class QueueMessage
    attr_reader :js

    def initialize(js)
      @js = js
    end

    def id
      js = @js
      `(#{js} && #{js}.id ? String(#{js}.id) : '')`
    end

    def timestamp
      js = @js
      ms = `(#{js} && #{js}.timestamp && typeof #{js}.timestamp.getTime === 'function' ? #{js}.timestamp.getTime() : null)`
      return nil if `#{ms} == null`
      Time.at(ms.to_f / 1000.0)
    end

    # Parsed body. Workers Queues gives us the structured clone of
    # whatever the producer sent, so this is usually already a Ruby
    # Hash / Array after crossing the JS<->Ruby boundary. Raw
    # strings pass through untouched — we deliberately do NOT attempt
    # to `JSON.parse` an opaque String here because Workers Queues
    # already structure-clones producer payloads, so a String body
    # means the producer really meant a String. Callers that did
    # encode a JSON string themselves can `JSON.parse(msg.body)` at
    # the call site.
    #
    # (Copilot review PR #9 flagged the earlier "JSON-looking strings
    # are parsed" comment — fixed by removing that claim.)
    def body
      return @body if defined?(@body)
      js = @js
      raw = `(#{js} && typeof #{js}.body !== 'undefined' ? #{js}.body : null)`
      @body = js_to_ruby(raw)
    end

    # Raw body as it came from JS — useful when the consumer wants to
    # see the unparsed value (e.g. a JSON string stored as-is).
    def raw_body
      js = @js
      `(#{js} && typeof #{js}.body !== 'undefined' ? #{js}.body : null)`
    end

    # Queues API: mark this message as successfully handled.
    def ack
      js = @js
      `(#{js} && typeof #{js}.ack === 'function' ? #{js}.ack() : null)`
      nil
    end

    # Queues API: request a retry. `delay_seconds:` caps the retry
    # backoff at a specific value.
    def retry(delay_seconds: nil)
      js = @js
      if delay_seconds
        ds = delay_seconds.to_i
        `(#{js} && typeof #{js}.retry === 'function' ? #{js}.retry({ delaySeconds: #{ds} }) : null)`
      else
        `(#{js} && typeof #{js}.retry === 'function' ? #{js}.retry() : null)`
      end
      nil
    end

    private

    def js_to_ruby(v)
      return nil if `#{v} == null`
      return v if `typeof #{v} === 'string' || typeof #{v} === 'number' || typeof #{v} === 'boolean'`
      if `Array.isArray(#{v})`
        out = []
        len = `#{v}.length`
        i = 0
        while i < len
          out << js_to_ruby(`#{v}[#{i}]`)
          i += 1
        end
        return out
      end
      if `typeof #{v} === 'object'`
        h = {}
        keys = `Object.keys(#{v})`
        len = `#{keys}.length`
        i = 0
        while i < len
          k = `#{keys}[#{i}]`
          h[k] = js_to_ruby(`#{v}[#{k}]`)
          i += 1
        end
        return h
      end
      v
    end
  end

  # Wraps the MessageBatch passed to `queue(batch, env, ctx)` in
  # worker.mjs. Exposes `queue` name, an Array of QueueMessage, and
  # batch-level ack/retry helpers.
  class QueueBatch
    attr_reader :js

    def initialize(js)
      @js = js
    end

    def queue
      js = @js
      `(#{js} && #{js}.queue ? String(#{js}.queue) : '')`
    end

    def messages
      return @messages if @messages
      js = @js
      arr = `(#{js} && Array.isArray(#{js}.messages) ? #{js}.messages : [])`
      out = []
      len = `#{arr}.length`
      i = 0
      while i < len
        out << QueueMessage.new(`#{arr}[#{i}]`)
        i += 1
      end
      @messages = out
    end

    def size
      messages.length
    end

    def ack_all
      js = @js
      `(#{js} && typeof #{js}.ackAll === 'function' ? #{js}.ackAll() : null)`
      nil
    end

    def retry_all(delay_seconds: nil)
      js = @js
      if delay_seconds
        ds = delay_seconds.to_i
        `(#{js} && typeof #{js}.retryAll === 'function' ? #{js}.retryAll({ delaySeconds: #{ds} }) : null)`
      else
        `(#{js} && typeof #{js}.retryAll === 'function' ? #{js}.retryAll() : null)`
      end
      nil
    end
  end

  # Consumer dispatcher. The Sinatra DSL (`consume_queue`) registers
  # handlers here via `Cloudflare::QueueConsumer.register(queue_name, unbound_method)`.
  # `src/worker.mjs#queue` calls `globalThis.__HOMURA_QUEUE_DISPATCH__`
  # which forwards into `dispatch_js` below.
  module QueueConsumer
    @handlers = {}

    class << self
      attr_reader :handlers
    end

    def self.register(queue_name, unbound_method)
      @handlers ||= {}
      @handlers[queue_name.to_s] = unbound_method
    end

    def self.handler_for(queue_name)
      (@handlers || {})[queue_name.to_s]
    end

    def self.handlers_by_queue
      (@handlers || {}).dup
    end

    # Dispatcher called from the JS hook. `js_batch` is the MessageBatch,
    # `js_env`, `js_ctx` are the Workers env and ExecutionContext.
    # Returns a Hash summary ({ queue:, handled:, size: }) for diagnostics.
    def self.dispatch_js(js_batch, js_env, js_ctx)
      batch = QueueBatch.new(js_batch)
      queue_name = batch.queue
      handler = handler_for(queue_name)
      if handler.nil?
        warn "[Cloudflare::QueueConsumer] no handler registered for queue #{queue_name.inspect}; messages will time out and retry"
        return { 'queue' => queue_name, 'handled' => false, 'size' => batch.size, 'reason' => 'no_handler' }
      end

      ctx = QueueContext.new(batch, js_env, js_ctx)
      result = handler.bind(ctx).call(batch)
      if `(#{result} != null && typeof #{result}.then === 'function')`
        result = result.__await__
      end
      { 'queue' => queue_name, 'handled' => true, 'size' => batch.size, 'result' => result.is_a?(Hash) ? result : nil }
    end

    # Single-line backtick (see scheduled.rb for the Opal multi-line
    # constraint). Logs+swallows thrown errors so one bad handler
    # doesn't crash the Workers queue consumer.
    def self.install_dispatcher
      mod = self
      `globalThis.__HOMURA_QUEUE_DISPATCH__ = async function(js_batch, js_env, js_ctx) { try { return await #{mod}.$dispatch_js(js_batch, js_env, js_ctx); } catch (err) { try { globalThis.console.error('[Cloudflare::QueueConsumer] dispatch failed:', err && err.stack || err); } catch (e) {} return { queue: (js_batch && js_batch.queue) || '', handled: false, size: (js_batch && Array.isArray(js_batch.messages) ? js_batch.messages.length : 0), error: String(err && err.message || err) }; } };(function(){var g=globalThis;g.__OPAL_WORKERS__=g.__OPAL_WORKERS__||{};g.__OPAL_WORKERS__.queue=g.__HOMURA_QUEUE_DISPATCH__;})();`
    end
  end

  # `self` inside a `consume_queue do |batch| ... end` block. Exposes
  # env / ctx helpers alongside the batch so the block can reach the
  # same D1 / KV / R2 bindings an HTTP route would. This keeps the
  # consumer side consistent with Phase 9's ScheduledContext.
  class QueueContext
    attr_reader :batch, :env, :js_env, :js_ctx

    def initialize(batch, js_env, js_ctx)
      @batch = batch
      @js_env = js_env
      @js_ctx = js_ctx
      @env = build_env(js_env)
    end

    def db;     env['cloudflare.DB'];     end
    def kv;     env['cloudflare.KV'];     end
    def bucket; env['cloudflare.BUCKET']; end

    # Hand a long-running promise to ctx.waitUntil. Mirrors the same
    # helper in Sinatra::Scheduled's ScheduledContext.
    def wait_until(promise)
      return promise if @js_ctx.nil?
      js_ctx = @js_ctx
      `#{js_ctx}.waitUntil(#{promise})`
      promise
    end

    private

    def build_env(js_env)
      env = {
        'cloudflare.queue' => true,
        'cloudflare.env'   => js_env,
        'cloudflare.ctx'   => @js_ctx
      }
      # js_env is a raw JS object when called from the Workers runtime,
      # so `.nil?` would explode with NoMethodError. Use a JS-level
      # null/undefined/Opal.nil check instead — same pattern
      # `Cloudflare::Cache#available?` uses.
      return env if `(#{js_env} == null || #{js_env} === undefined || #{js_env} === Opal.nil)`
      js_db = `#{js_env} && #{js_env}.DB`
      js_kv = `#{js_env} && #{js_env}.KV`
      js_r2 = `#{js_env} && #{js_env}.BUCKET`
      env['cloudflare.DB']     = Cloudflare::D1Database.new(js_db)  if `#{js_db} != null`
      env['cloudflare.KV']     = Cloudflare::KVNamespace.new(js_kv) if `#{js_kv} != null`
      env['cloudflare.BUCKET'] = Cloudflare::R2Bucket.new(js_r2)    if `#{js_r2} != null`
      env
    end
  end
end

Cloudflare::QueueConsumer.install_dispatcher
