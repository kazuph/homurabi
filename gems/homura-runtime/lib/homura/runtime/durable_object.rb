# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Durable Objects binding wrapper.
#
# Cloudflare Durable Objects (DO) give a Worker a single-writer, strongly
# consistent storage actor reachable by name or unique id. The runtime
# instantiates ONE instance per DO id per colo and routes every `stub.fetch`
# to the same instance, so the user can build counters, rate limiters,
# session servers, and collaborative state machines without any external
# store.
#
# Three responsibilities here, analogous to `homura/runtime.rb`'s
# D1 / KV / R2 section:
#
#   1. `Cloudflare::DurableObjectNamespace`  — wraps the binding JS object
#      (`env.COUNTER`). Exposes `.id_from_name(str)` / `.new_unique_id` /
#      `.get(id)` / `.get_by_name(str)` so routes never need backticks.
#
#   2. `Cloudflare::DurableObjectStub`       — wraps the stub returned by
#      `namespace.get(id)`. Its `#fetch(url_or_request, init = nil)` posts
#      to the DO and returns a `Cloudflare::HTTPResponse` (reusing the
#      Phase 6 shape) after awaiting body text.
#
#   3. Ruby-side DO handlers                  — the DO class logic itself.
#      A Sinatra-like DSL (`Cloudflare::DurableObject.define 'Counter' do ... end`)
#      registers a Ruby block that is invoked from the JS DO class
#      (defined in `src/worker.mjs`) once per incoming request. Each
#      block runs inside a `DurableObjectRequestContext` that exposes
#      `state.storage` (get/put/delete/list), `env` (bindings), and
#      `request` (the HTTP request).
#
# The JS side (src/worker.mjs) exports a generic `HomuraCounterDO`
# class whose constructor + fetch forward to Ruby through
# `globalThis.__HOMURA_DO_DISPATCH__(class_name, state, env, req_init)`.
# That hook is installed by this file on load, mirroring the scheduled
# dispatcher pattern from Phase 9.
#
# WebSockets are deferred to the next phase — this wrapper focuses on
# HTTP fetch-style interaction with DO instances, which is enough for
# counters / session state / rate limiters.

require 'json'

module Cloudflare
  class DurableObjectError < StandardError
    attr_reader :operation, :do_class
    def initialize(message, operation: nil, do_class: nil)
      @operation = operation
      @do_class  = do_class
      super("[Cloudflare::DurableObject] class=#{do_class || '?'} op=#{operation || 'fetch'}: #{message}")
    end
  end

  # Wraps a JS DurableObjectId (opaque token returned by
  # `namespace.idFromName(...)` / `namespace.newUniqueId()`). Carries
  # the raw JS id so we can round-trip it into `namespace.get(id)`.
  class DurableObjectId
    attr_reader :js_id

    def initialize(js_id)
      @js_id = js_id
    end

    # Hex string representation (stable across invocations for a named id).
    def to_s
      js = @js_id
      `(#{js} && typeof #{js}.toString === 'function' ? #{js}.toString() : String(#{js} || ''))`
    end
  end

  # Wraps a DurableObjectNamespace binding (env.COUNTER). The binding
  # object itself is opaque; we only need three methods from it —
  # idFromName, newUniqueId, get — but we also expose a high-level
  # `get_by_name` helper because "get a stub by name" is the most
  # common call site and the unwrapped form requires two steps.
  class DurableObjectNamespace
    def initialize(js)
      @js = js
    end

    # Hash-derived DurableObjectId. Two calls with the same `name` in
    # the same namespace return equal ids, so `get_by_name("foo")` is
    # the idiomatic "single-writer per name" pattern.
    def id_from_name(name)
      js_ns = @js
      DurableObjectId.new(`#{js_ns}.idFromName(#{name.to_s})`)
    end

    # Random unique DurableObjectId. Used when the caller wants an
    # ephemeral / request-scoped actor (e.g. one DO per user session).
    def new_unique_id
      js_ns = @js
      DurableObjectId.new(`#{js_ns}.newUniqueId()`)
    end

    # Parse a hex id string back into a DurableObjectId. Matches the
    # Workers `namespace.idFromString(hex)` method.
    def id_from_string(hex)
      js_ns = @js
      DurableObjectId.new(`#{js_ns}.idFromString(#{hex.to_s})`)
    end

    # Get a stub for an id (or a DurableObjectId wrapper).
    def get(id)
      js_ns = @js
      js_id = id.is_a?(DurableObjectId) ? id.js_id : id
      DurableObjectStub.new(`#{js_ns}.get(#{js_id})`)
    end

    # Convenience: derive id-from-name and return the stub in one call.
    #
    #   stub = env_ns.get_by_name('global-counter')
    #   resp = stub.fetch('/inc').__await__
    def get_by_name(name)
      get(id_from_name(name))
    end
  end

  # Wraps a stub (the object returned by `namespace.get(id)`). Its only
  # callable method is `fetch(request)`, which submits an HTTP request
  # to the DO instance and returns a `Response`. We return the same
  # `Cloudflare::HTTPResponse` shape as Phase 6 so routes don't need to
  # learn a second API.
  class DurableObjectStub
    attr_reader :js

    def initialize(js)
      @js = js
    end

    # Same as `fetch` but returns the raw JS Response (a JS Promise
    # resolving to it) instead of wrapping it in a
    # `Cloudflare::HTTPResponse`. Needed for WebSocket-upgrade
    # responses — the 101 Response carries its WebSocket in a
    # `.webSocket` property that disappears if we reconstruct the
    # Response via the HTTPResponse wrapper.
    def fetch_raw(url_or_request, method: 'GET', headers: nil, body: nil)
      hdrs = headers || {}
      method_str = method.to_s.upcase
      js_headers = Cloudflare::HTTP.ruby_headers_to_js(hdrs)
      js_body = body.nil? ? nil : body.to_s
      url_str = url_or_request.to_s
      js_stub = @js
      err_klass = Cloudflare::DurableObjectError
      `(async function(stub, url_str, method_str, js_headers, js_body, Kernel, err_klass) { var init = { method: method_str, headers: js_headers }; if (js_body !== null && js_body !== undefined && js_body !== Opal.nil) { init.body = js_body; } try { return await stub.fetch(url_str, init); } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'stub.fetch_raw' }))); } })(#{js_stub}, #{url_str}, #{method_str}, #{js_headers}, #{js_body}, #{Kernel}, #{err_klass})`
    end

    # Call the DO with a plain URL (String) and optional init-Hash. The
    # DO's fetch handler sees the URL as-is (no routing layer strips
    # the prefix), so user code can use any pathname it wants as its
    # internal DO command channel. Returns a JS Promise the caller
    # `__await__`s to get a `Cloudflare::HTTPResponse`.
    def fetch(url_or_request, method: 'GET', headers: nil, body: nil)
      js_stub = @js
      hdrs = headers || {}
      method_str = method.to_s.upcase
      js_headers = Cloudflare::HTTP.ruby_headers_to_js(hdrs)
      js_body = body.nil? ? nil : body.to_s
      url_str = url_or_request.to_s
      err_klass = Cloudflare::DurableObjectError
      response_klass = Cloudflare::HTTPResponse
      do_class_label = 'DurableObjectStub'

      # Single-line IIFE — see `lib/homura/runtime/cache.rb#put`
      # for why Opal can silently drop a multi-line x-string Promise.
      js_promise = `(async function(stub, url_str, method_str, js_headers, js_body, Kernel, err_klass, do_class_label) { var init = { method: method_str, headers: js_headers }; if (js_body !== null && js_body !== undefined && js_body !== Opal.nil) { init.body = js_body; } var resp; try { resp = await stub.fetch(url_str, init); } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'stub.fetch', do_class: do_class_label }))); } var text = ''; try { text = await resp.text(); } catch (_) { text = ''; } var hk = []; var hv = []; if (resp.headers && typeof resp.headers.forEach === 'function') { resp.headers.forEach(function(v, k) { hk.push(String(k).toLowerCase()); hv.push(String(v)); }); } return { status: resp.status|0, text: text, hkeys: hk, hvals: hv }; })(#{js_stub}, #{url_str}, #{method_str}, #{js_headers}, #{js_body}, #{Kernel}, #{err_klass}, #{do_class_label})`

      js_result = js_promise.__await__
      hkeys = `#{js_result}.hkeys`
      hvals = `#{js_result}.hvals`
      h = {}
      i = 0
      len = `#{hkeys}.length`
      while i < len
        h[`#{hkeys}[#{i}]`] = `#{hvals}[#{i}]`
        i += 1
      end

      response_klass.new(
        status:  `#{js_result}.status`,
        headers: h,
        body:    `#{js_result}.text`,
        url:     url_str
      )
    end
  end

  # -----------------------------------------------------------------
  # Ruby-side DO class registry + DSL.
  #
  # The JS side (src/worker.mjs) defines a single `HomuraCounterDO`
  # export. When the DO runtime instantiates it and calls its fetch,
  # the JS class hands the call off to
  # `globalThis.__HOMURA_DO_DISPATCH__(class_name, state, env, request, body_text)`.
  # We dispatch to whichever Ruby handler block was registered for
  # `class_name` via `Cloudflare::DurableObject.define`.
  # -----------------------------------------------------------------

  module DurableObject
    @handlers = {}

    class << self
      attr_reader :handlers
    end

    # Register a Ruby handler for a DO class.
    #
    #   Cloudflare::DurableObject.define('HomuraCounterDO') do |state, request|
    #     prev = (state.storage.get('count').__await__ || 0).to_i
    #     if request.path == '/inc'
    #       state.storage.put('count', prev + 1).__await__
    #       [200, { 'content-type' => 'application/json' }, { 'count' => prev + 1 }.to_json]
    #     elsif request.path == '/reset'
    #       state.storage.delete('count').__await__
    #       [200, { 'content-type' => 'application/json' }, '{"reset":true}']
    #     else
    #       [200, { 'content-type' => 'application/json' }, { 'count' => prev }.to_json]
    #     end
    #   end
    #
    # The block must return a Rack-style triple `[status, headers, body]`.
    # `body` may be a String or an object that responds to `to_s`.
    def self.define(class_name, &block)
      raise ArgumentError, 'define requires a block' unless block
      raise ArgumentError, 'class_name must be a String' unless class_name.is_a?(String)
      @handlers ||= {}
      # Wrap via define_method so Opal's `# await: true` picks it up as
      # async (same trick Sinatra::Scheduled uses for its jobs).
      method_name = "__do_handler_#{class_name.gsub(/[^A-Za-z0-9_]/, '_')}".to_sym
      DurableObjectRequestContext.send(:define_method, method_name, &block)
      unbound = DurableObjectRequestContext.instance_method(method_name)
      DurableObjectRequestContext.send(:remove_method, method_name)
      @handlers[class_name] = unbound
      nil
    end

    # Register a WebSocket-event handler for a DO class. Accepts any
    # combination of `on_message: proc { |ws, msg, state| ... }`,
    # `on_close: proc { |ws, code, reason, clean, state| ... }`,
    # `on_error: proc { |ws, err, state| ... }`.
    #
    #   Cloudflare::DurableObject.define_web_socket_handlers('HomuraCounterDO',
    #     on_message: ->(ws, msg, _state) { `#{ws}.send(#{msg})` },
    #     on_close:   ->(ws, code, reason, clean, _state) { `#{ws}.close(#{code}, #{reason})` }
    #   )
    #
    # The callbacks are invoked from `webSocketMessage` /
    # `webSocketClose` / `webSocketError` dispatches on the JS DO
    # class (wired by the exported HomuraCounterDO in
    # src/worker.mjs). Return value is ignored — the runtime doesn't
    # expect a body.
    def self.define_web_socket_handlers(class_name, on_message: nil, on_close: nil, on_error: nil)
      @ws_handlers ||= {}
      @ws_handlers[class_name] = {
        on_message: on_message,
        on_close:   on_close,
        on_error:   on_error
      }.compact
      nil
    end

    def self.web_socket_handlers_for(class_name)
      (@ws_handlers || {})[class_name.to_s]
    end

    # Lookup handler by class name.
    def self.handler_for(class_name)
      (@handlers || {})[class_name.to_s]
    end

    # Dispatcher called from the JS DO class. Returns a JS Promise that
    # resolves to a JS Response.
    def self.dispatch_js(class_name, js_state, js_env, js_request, body_text)
      handler = handler_for(class_name)
      if handler.nil?
        body = { 'error' => "no Ruby handler for DurableObject class #{class_name}" }.to_json
        return build_js_response(500, { 'content-type' => 'application/json' }, body)
      end

      state = DurableObjectState.new(js_state)
      request = DurableObjectRequest.new(js_request, body_text)
      ctx = DurableObjectRequestContext.new(state, js_env, request)

      result = handler.bind(ctx).call(state, request)

      # If the block itself was async (used __await__ internally), its
      # return value is a Promise — await it so the caller sees the
      # resolved triple.
      if `(#{result} != null && typeof #{result}.then === 'function')`
        result = result.__await__
      end

      status, headers, body = normalise_response(result)
      build_js_response(status, headers, body)
    end

    # Accept common return shapes from the user block:
    #   - Array triple [status, headers, body]
    #   - Hash   {status:, headers:, body:}
    #   - String (200 OK, text/plain)
    def self.normalise_response(result)
      if result.is_a?(Array) && result.length == 3
        [result[0].to_i, result[1] || {}, result[2].to_s]
      elsif result.is_a?(Hash)
        [
          (result['status'] || result[:status] || 200).to_i,
          result['headers'] || result[:headers] || {},
          (result['body'] || result[:body] || '').to_s
        ]
      else
        [200, { 'content-type' => 'text/plain; charset=utf-8' }, result.to_s]
      end
    end

    def self.build_js_response(status, headers, body)
      js_headers = `({})`
      headers.each do |k, v|
        ks = k.to_s
        vs = v.to_s
        `#{js_headers}[#{ks}] = #{vs}`
      end
      status_int = status.to_i
      body_str = body.to_s
      `new Response(#{body_str}, { status: #{status_int}, headers: #{js_headers} })`
    end

    # WebSocket dispatchers — called from the JS DO class's
    # `webSocketMessage` / `webSocketClose` / `webSocketError`
    # methods. Each returns a JS Promise that resolves to undefined.
    def self.dispatch_ws_message(class_name, js_ws, js_message, js_state, js_env)
      h = web_socket_handlers_for(class_name)
      return nil if h.nil? || h[:on_message].nil?
      state = DurableObjectState.new(js_state)
      h[:on_message].call(js_ws, js_message, state)
      nil
    end

    def self.dispatch_ws_close(class_name, js_ws, code, reason, was_clean, js_state, js_env)
      h = web_socket_handlers_for(class_name)
      return nil if h.nil? || h[:on_close].nil?
      state = DurableObjectState.new(js_state)
      h[:on_close].call(js_ws, code, reason, was_clean, state)
      nil
    end

    def self.dispatch_ws_error(class_name, js_ws, js_error, js_state, js_env)
      h = web_socket_handlers_for(class_name)
      return nil if h.nil? || h[:on_error].nil?
      state = DurableObjectState.new(js_state)
      h[:on_error].call(js_ws, js_error, state)
      nil
    end

    # Install the JS dispatcher hook. Idempotent.
    #
    # Kept as a single-line backtick x-string — Opal's compiler refuses
    # multi-line backticks as expressions (same constraint documented
    # in `lib/homura/runtime/scheduled.rb#install_dispatcher`).
    # Installs FOUR hooks: fetch dispatcher + 3 websocket event
    # dispatchers. Each wraps Ruby exceptions in a console.error so a
    # bad handler doesn't crash the DO.
    def self.install_dispatcher
      mod = self
      `globalThis.__HOMURA_DO_DISPATCH__ = async function(class_name, state, env, request, body_text) { try { return await #{mod}.$dispatch_js(class_name, state, env, request, body_text == null ? '' : body_text); } catch (err) { try { globalThis.console.error('[Cloudflare::DurableObject] dispatch failed:', err && err.stack || err); } catch (e) {} return new Response(JSON.stringify({ error: String(err && err.message || err) }), { status: 500, headers: { 'content-type': 'application/json' } }); } };`
      `globalThis.__HOMURA_DO_WS_MESSAGE__ = async function(class_name, ws, message, state, env) { try { await #{mod}.$dispatch_ws_message(class_name, ws, message, state, env); } catch (err) { try { globalThis.console.error('[Cloudflare::DurableObject] ws.message dispatch failed:', err && err.stack || err); } catch (e) {} } };`
      `globalThis.__HOMURA_DO_WS_CLOSE__ = async function(class_name, ws, code, reason, wasClean, state, env) { try { await #{mod}.$dispatch_ws_close(class_name, ws, code, reason, wasClean, state, env); } catch (err) { try { globalThis.console.error('[Cloudflare::DurableObject] ws.close dispatch failed:', err && err.stack || err); } catch (e) {} } };`
      `globalThis.__HOMURA_DO_WS_ERROR__ = async function(class_name, ws, err, state, env) { try { await #{mod}.$dispatch_ws_error(class_name, ws, err, state, env); } catch (e2) { try { globalThis.console.error('[Cloudflare::DurableObject] ws.error dispatch failed:', e2 && e2.stack || e2); } catch (_) {} } };`
      `(function(){var g=globalThis;g.__OPAL_WORKERS__=g.__OPAL_WORKERS__||{};var d=g.__OPAL_WORKERS__.durableObject=g.__OPAL_WORKERS__.durableObject||{};d.dispatch=g.__HOMURA_DO_DISPATCH__;d.wsMessage=g.__HOMURA_DO_WS_MESSAGE__;d.wsClose=g.__HOMURA_DO_WS_CLOSE__;d.wsError=g.__HOMURA_DO_WS_ERROR__;})();`
    end
  end

  # -----------------------------------------------------------------
  # DurableObjectState — wraps the `state` object passed to the DO's
  # fetch(). Only exposes `.storage` because that is the one piece of
  # state DO code touches >99% of the time. Future additions
  # (blockConcurrencyWhile, waitUntil, etc.) can come here.
  # -----------------------------------------------------------------
  class DurableObjectState
    attr_reader :js_state, :storage

    def initialize(js_state)
      @js_state = js_state
      @storage  = DurableObjectStorage.new(`#{js_state} && #{js_state}.storage`)
    end

    # Unique id of this DO instance as a hex String.
    def id
      js_state = @js_state
      `(#{js_state} && #{js_state}.id && typeof #{js_state}.id.toString === 'function' ? #{js_state}.id.toString() : '')`
    end

    # Wrap a Promise in state.blockConcurrencyWhile(...) so that no
    # other fetch to this DO can run until the promise resolves. Rare
    # but critical for consistent read-modify-write against storage.
    def block_concurrency_while(promise)
      js_state = @js_state
      `(#{js_state} && #{js_state}.blockConcurrencyWhile ? #{js_state}.blockConcurrencyWhile(async function(){ return await #{promise}; }) : #{promise})`
    end

    # Accept an incoming WebSocket for the Hibernation API. The DO
    # instance transparently survives `webSocketMessage` /
    # `webSocketClose` callbacks even if the isolate goes idle in
    # between — the runtime wakes the DO, invokes the callback, and
    # lets it hibernate again. Without `acceptWebSocket`, the DO must
    # stay alive for the lifetime of the socket (billed per-invocation
    # second).
    #
    # `tags` is an optional Array of string tags attached to the
    # socket so callers can later filter `get_web_sockets(tag: ...)`.
    def accept_web_socket(js_ws, tags: nil)
      js_state = @js_state
      if tags && !tags.empty?
        js_tags = `([])`
        tags.each { |t| ts = t.to_s; `#{js_tags}.push(#{ts})` }
        `#{js_state}.acceptWebSocket(#{js_ws}, #{js_tags})`
      else
        `#{js_state}.acceptWebSocket(#{js_ws})`
      end
      nil
    end

    # List every WebSocket the runtime has attached to this DO via
    # `acceptWebSocket`. Optional `tag:` filter forwards to
    # `getWebSockets(tag)`.
    def web_sockets(tag: nil)
      js_state = @js_state
      js_arr = if tag
                 ts = tag.to_s
                 `(#{js_state}.getWebSockets ? #{js_state}.getWebSockets(#{ts}) : [])`
               else
                 `(#{js_state}.getWebSockets ? #{js_state}.getWebSockets() : [])`
               end
      out = []
      len = `#{js_arr}.length`
      i = 0
      while i < len
        out << `#{js_arr}[#{i}]`
        i += 1
      end
      out
    end
  end

  # Thin Ruby wrapper around state.storage.
  # Values are serialised to JSON on `put` and parsed on `get`, so user
  # code can pass/retrieve plain Ruby Hashes, Arrays, numbers, strings,
  # booleans without reaching for a backtick.
  class DurableObjectStorage
    def initialize(js_storage)
      @js = js_storage
    end

    # Returns a JS Promise resolving to the stored Ruby value, or nil.
    def get(key)
      js = @js
      err_klass = Cloudflare::DurableObjectError
      `#{js}.get(#{key.to_s}).then(function(v) { if (v == null) return nil; if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return v; } } return v; }).catch(function(e) { #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'storage.get' }))); })`
    end

    # Store any JSON-serialisable Ruby value. Always serialises via
    # `to_json` to avoid the JS-side "{$$is_hash:true}" Opal leakage.
    # Returns a JS Promise.
    def put(key, value)
      js = @js
      err_klass = Cloudflare::DurableObjectError
      js_value = value.nil? ? 'null' : value.to_json
      `#{js}.put(#{key.to_s}, #{js_value}).catch(function(e) { #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'storage.put' }))); })`
    end

    # Remove a key. Returns a JS Promise resolving to a boolean (true
    # if a key was deleted). We coerce to Ruby true/false.
    def delete(key)
      js = @js
      err_klass = Cloudflare::DurableObjectError
      `#{js}.delete(#{key.to_s}).then(function(v) { return v ? true : false; }).catch(function(e) { #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'storage.delete' }))); })`
    end

    # Clear every key. Returns a JS Promise.
    def delete_all
      js = @js
      err_klass = Cloudflare::DurableObjectError
      `#{js}.deleteAll().catch(function(e) { #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'storage.deleteAll' }))); })`
    end

    # List keys. Returns a JS Promise resolving to a Ruby `Hash`
    # of `{ key => parsed-value }` (values are JSON-parsed when they
    # round-tripped through `put`; opaque strings are returned as-is).
    # Options `prefix:`, `limit:`, `reverse:`, `start:`, `end_key:`
    # forward to the underlying Workers `storage.list({...})` call.
    #
    # The earlier iteration returned a JS `Map`; that was documented as
    # a Ruby Hash but forced callers to reach for JS iteration, which
    # Copilot review (#9) flagged. The JS side still builds the
    # intermediate Map (the Workers runtime also gives us a Map) and we
    # copy it into a Ruby Hash before resolving so downstream code can
    # use `each` / `[]` / `keys` without backticks.
    def list(prefix: nil, limit: nil, reverse: nil, start: nil, end_key: nil)
      js = @js
      err_klass = Cloudflare::DurableObjectError
      js_opts = `({})`
      `#{js_opts}.prefix  = #{prefix.to_s}` unless prefix.nil?
      `#{js_opts}.limit   = #{limit.to_i}`  unless limit.nil?
      `#{js_opts}.reverse = #{!!reverse}`   unless reverse.nil?
      `#{js_opts}.start   = #{start.to_s}`  unless start.nil?
      `#{js_opts}.end     = #{end_key.to_s}` unless end_key.nil?
      js_promise = `#{js}.list(#{js_opts}).catch(function(e) { #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'storage.list' }))); })`
      js_result = js_promise.__await__
      out = {}
      return out if `#{js_result} == null`
      `(#{js_result}.forEach && typeof #{js_result}.forEach === 'function') && #{js_result}.forEach(function(v, k) { var pv = v; if (typeof pv === 'string') { try { pv = JSON.parse(pv); } catch (_) {} } #{out}.$store(String(k), pv); })`
      out
    end
  end

  # The incoming `request` argument passed to DO handlers. `body_text`
  # is pre-awaited by the JS dispatcher because Ruby runs synchronously
  # under Opal (same pattern as `Rack::Handler::Homura.call`).
  class DurableObjectRequest
    attr_reader :js_request, :body

    def initialize(js_request, body_text = '')
      @js_request = js_request
      @body = body_text.to_s
    end

    def method
      js = @js_request
      `(#{js} ? String(#{js}.method || 'GET') : 'GET')`
    end

    def url
      js = @js_request
      `(#{js} ? String(#{js}.url || '') : '')`
    end

    def path
      u = url
      return '' if u.nil? || u.empty?
      begin
        # Extract pathname via URL() so relative paths aren't mangled.
        u_str = u
        `new URL(#{u_str}).pathname`
      rescue StandardError
        # Fallback regex — strip scheme+host, keep everything up to ?/#.
        m = u.match(%r{\Ahttps?://[^/]+([^?#]*)})
        m ? m[1] : u
      end
    end

    # Shallow header Hash with lowercased keys.
    def headers
      return @headers if @headers
      h = {}
      js = @js_request
      `(#{js} && #{js}.headers && typeof #{js}.headers.forEach === 'function') && #{js}.headers.forEach(function(v, k) { #{h}.$store(String(k).toLowerCase(), String(v)); })`
      @headers = h
    end

    def [](name)
      headers[name.to_s.downcase]
    end

    def json
      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end

  # `self` inside a DurableObject.define block. Exposes state / env /
  # request so user code reads like a regular Sinatra handler.
  class DurableObjectRequestContext
    attr_reader :state, :env, :request

    def initialize(state, env, request)
      @state = state
      @env = env
      @request = request
    end

    def storage; @state.storage; end
  end
end

# Auto-install the JS-side dispatcher on load, mirroring the scheduled
# dispatcher. Safe even if the worker never uses DO — the hook is only
# invoked when a DO class is instantiated by the Workers runtime.
Cloudflare::DurableObject.install_dispatcher
