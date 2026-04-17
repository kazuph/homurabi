# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11B — Cloudflare Cache API wrapper.
#
# The Cache API (`caches.default`, `caches.open(name)`) is an edge
# cache local to the colo that serves a request. Unlike KV, there is
# no binding; the `caches` global is always present on Workers.
#
# Semantics are HTTP-level: the cache key is a Request (method, URL,
# headers — Vary-aware), and the value is a full Response with
# headers, status, and body. `cache.match(req)` returns a Response or
# nil; `cache.put(req, resp)` stores it. This wrapper exposes the
# subset that matters for Ruby routes:
#
#   cache = Cloudflare::Cache.default
#   resp  = cache.match(request.url).__await__
#   if resp
#     # serve from cache
#   else
#     # compute…
#     cache.put(request.url, body, headers: { 'cache-control' => 'public, max-age=60' }).__await__
#   end
#
# The Sinatra helper `cache_get(url_or_request) { block }` (exposed
# through user-side `helpers do ... end`) wraps the match/compute/put
# dance so routes can write:
#
#   get '/demo/cache/heavy' do
#     cache_get(request.url, ttl: 60, content_type: 'application/json') do
#       compute_expensive_value.to_json
#     end
#   end
#
# Both the helper and the low-level API await under the hood, so
# routes only need a single `.__await__` at the call site if they use
# the raw wrapper directly.
#
# LIMITATION — on Cloudflare Workers, `cache.put` only honours the
# key URL's scheme/host/path, and the URL must have an HTTP(S)
# scheme. In `wrangler dev`'s local mode the cache is a noop unless
# `--local` is combined with miniflare's cache (>= wrangler 3.x
# defaults). We document this in the README and the helper logs a
# single console.warn on the first noop put so misconfiguration is
# visible rather than silent.

module Cloudflare
  class CacheError < StandardError
    attr_reader :operation
    def initialize(message, operation: nil)
      @operation = operation
      super("[Cloudflare::Cache] op=#{operation || 'match'}: #{message}")
    end
  end

  # Wrapper around a JS Cache object (caches.default or a named cache).
  class Cache
    attr_reader :js_cache, :name

    # caches.default — the shared cache that every Worker gets for free.
    # Returns a fresh wrapper each call; the underlying JS object is a
    # singleton per isolate.
    def self.default
      Cache.new(`(typeof caches !== 'undefined' && caches ? caches.default : null)`, 'default')
    end

    # caches.open(name) — named cache partitions. Returns a JS Promise
    # resolving to a wrapped Cache. Following Workers conventions, the
    # wrapper itself holds the resolved JS Cache so subsequent calls
    # don't re-open the handle.
    def self.open(name)
      name_str = name.to_s
      js_promise = `(typeof caches !== 'undefined' && caches && caches.open ? caches.open(#{name_str}) : Promise.resolve(null))`
      js_cache = js_promise.__await__
      Cache.new(js_cache, name_str)
    end

    def initialize(js_cache, name = 'default')
      @js_cache = js_cache
      @name = name.to_s
    end

    # True when the underlying JS cache is present. In unusual runtimes
    # (tests / non-Workers hosts) `caches` may be undefined. We check
    # Ruby-nil first because Opal's `nil` marshals to an object (not
    # JS null) so a bare `#{js} != null` would be truthy — this is the
    # same pitfall `Cloudflare::AI.run` documents for `env.AI`.
    def available?
      js = @js_cache
      # Opal marshals Ruby `nil` to a runtime sentinel (`Opal.nil`),
      # not JS null / undefined. Compare against the sentinel
      # explicitly so a Cache built with Ruby `nil` reports itself as
      # unavailable (which the non-Workers tests rely on).
      !!`(#{js} !== null && #{js} !== undefined && #{js} !== Opal.nil)`
    end

    # Look up a Request (or URL String) in the cache. Returns a JS
    # Promise resolving to a Cloudflare::HTTPResponse (populated with
    # body text + headers) or nil.
    def match(request_or_url)
      js = @js_cache
      response_klass = Cloudflare::HTTPResponse
      err_klass = Cloudflare::CacheError
      req = request_to_js(request_or_url)
      url_str = request_or_url.to_s

      # Single-line backtick IIFE — see `put` for the Opal multi-line
      # x-string quirk that silently drops the returned Promise.
      js_promise = `(async function(js, req, Kernel, err_klass) { if (js == null || js === Opal.nil) return null; var cached; try { cached = await js.match(req); } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'match' }))); } if (cached == null) return null; var text = ''; try { text = await cached.text(); } catch (_) { text = ''; } var hk = []; var hv = []; if (cached.headers && typeof cached.headers.forEach === 'function') { cached.headers.forEach(function(v, k) { hk.push(String(k).toLowerCase()); hv.push(String(v)); }); } return { status: cached.status|0, text: text, hkeys: hk, hvals: hv }; })(#{js}, #{req}, #{Kernel}, #{err_klass})`
      js_result = js_promise.__await__
      return nil if `#{js_result} == null`

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

    # Store a Response for the given Request/URL.
    #
    #   cache.put(request.url, body_str,
    #             status: 200,
    #             headers: { 'content-type' => 'application/json',
    #                        'cache-control' => 'public, max-age=60' }).__await__
    #
    # Returns a JS Promise that resolves to nil. Workers refuses to
    # store responses without a cacheable status / cache-control; we
    # surface that as a CacheError rather than silently succeeding.
    def put(request_or_url, body, status: 200, headers: {})
      js = @js_cache
      err_klass = Cloudflare::CacheError
      req = request_to_js(request_or_url)
      hdrs = ruby_headers_to_js(headers)
      body_str = body.to_s
      status_int = status.to_i

      # Single-line backtick IIFE — multi-line form is parsed by Opal
      # as a statement (not an expression), so the returned Promise
      # gets dropped and the caller's `__await__` receives `undefined`
      # instead of waiting for `cache.put` to resolve. That was the
      # silent bug: the inner `await` ran, but the outer await had
      # already proceeded. See lib/cloudflare_workers/scheduled.rb for
      # the same Opal multi-line x-string constraint.
      # Warn ONCE per isolate on a nil cache. Non-Workers runtimes
      # hit `Cache.new(nil, ...)` intentionally (tests, safe fall-back
      # for routes that can run without caching) and repeated warn
      # output would drown signal in noise — Copilot review PR #9.
      `(async function(js, req, body_str, status_int, hdrs, Kernel, err_klass) { if (js == null || js === Opal.nil) { try { if (!globalThis.__HOMURABI_CACHE_NOOP_WARNED__) { globalThis.__HOMURABI_CACHE_NOOP_WARNED__ = true; globalThis.console.warn('[Cloudflare::Cache] caches.default unavailable; skipping put (this is expected in non-Workers runtimes). Further warnings suppressed.'); } } catch (_) {} return null; } try { var resp = new Response(String(body_str), { status: status_int, headers: hdrs }); await js.put(req, resp); } catch (e) { try { globalThis.console.error('[Cloudflare::Cache] put threw:', e && e.stack || e); } catch (_) {} Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'put' }))); } return null; })(#{js}, #{req}, #{body_str}, #{status_int}, #{hdrs}, #{Kernel}, #{err_klass})`
    end

    # Remove a Request/URL from the cache. Returns a JS Promise
    # resolving to a boolean — true if an entry was removed.
    def delete(request_or_url)
      js = @js_cache
      err_klass = Cloudflare::CacheError
      req = request_to_js(request_or_url)
      # Single-line IIFE — see `put` for the Opal multi-line quirk.
      `(async function(js, req, Kernel, err_klass) { if (js == null || js === Opal.nil) return false; try { var deleted = await js.delete(req); return deleted ? true : false; } catch (e) { Kernel.$raise(err_klass.$new(e && e.message ? e.message : String(e), Opal.hash({ operation: 'delete' }))); } return false; })(#{js}, #{req}, #{Kernel}, #{err_klass})`
    end

    private

    # Normalise Ruby inputs (String URL, Cloudflare::HTTPResponse,
    # raw JS Request) to a JS Request. Passing a String URL is the
    # common case; Workers accepts that directly.
    def request_to_js(request_or_url)
      return request_or_url if `(#{request_or_url} != null && typeof #{request_or_url} === 'object' && typeof #{request_or_url}.url === 'string')`
      url_str = request_or_url.to_s
      `new Request(#{url_str})`
    end

    def ruby_headers_to_js(hash)
      js_obj = `({})`
      (hash || {}).each do |k, v|
        ks = k.to_s
        vs = v.to_s
        `#{js_obj}[#{ks}] = #{vs}`
      end
      js_obj
    end
  end

  # Module-level alias so calling code reads naturally:
  #   resp = Cloudflare::Cache.default.match(url).__await__
  # mirrors Phase 3's `Cloudflare::D1Database` / `Cloudflare::KVNamespace`
  # "the wrapper IS the API" pattern.
end
