// Cloudflare Workers Module Worker that hosts a pure Rack application
// compiled from Ruby by Opal. The Ruby side is a regular Rack app that
// would also run on Puma, Unicorn, etc.; this file is the Rack server
// adapter on the JavaScript side.
//
// The imported bundle (build/hello.no-exit.mjs) installs
// `globalThis.__HOMURABI_RACK_DISPATCH__` via lib/cloudflare_workers.rb's
// Rack::Handler::CloudflareWorkers. We forward every fetch event through
// it and return whatever JS Response the Ruby Rack app produced.

// Phase 7: expose node:crypto on globalThis BEFORE the Opal bundle
// loads so Digest / OpenSSL / SecureRandom can use synchronous APIs.
import "./setup-node-crypto.mjs";

import "../build/hello.no-exit.mjs";

export default {
  async fetch(request, env, ctx) {
    const dispatch = globalThis.__HOMURABI_RACK_DISPATCH__;
    if (typeof dispatch !== "function") {
      return new Response(
        "homurabi: Rack dispatcher not installed (Rack::Handler::CloudflareWorkers.run never called)\n",
        { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }

    // Read the body here while we still have the async context. The Opal
    // side runs synchronous Ruby, so it cannot `await req.text()` inside
    // the dispatcher. For methods that are defined to have no body
    // (GET, HEAD, OPTIONS by spec) we skip the read entirely to avoid
    // wasting a round-trip.
    let bodyText = "";
    const method = request.method.toUpperCase();
    if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
      try {
        bodyText = await request.text();
      } catch (err) {
        // Body read failure is a client error — surface it explicitly
        // instead of silently falling through with an empty string.
        return new Response(
          JSON.stringify({ error: "failed to read request body", detail: err.message }),
          { status: 400, headers: { "content-type": "application/json" } },
        );
      }
    }

    return dispatch(request, env, ctx, bodyText);
  },

  // Phase 9 — Cloudflare Workers Cron Triggers entry point.
  //
  // The Workers runtime invokes this `scheduled` export once per
  // matching `[triggers] crons` entry in wrangler.toml. We forward
  // the (event, env, ctx) triple to the Ruby-side dispatcher
  // installed by `lib/cloudflare_workers/scheduled.rb`
  // (which registers `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`).
  //
  // The Ruby dispatcher walks every job registered via the
  // Sinatra DSL `schedule '*/5 * * * *' do ... end` and runs
  // each one whose cron pattern matches `event.cron`.
  //
  // Local manual triggering (no cron poll wait):
  //   wrangler dev --test-scheduled
  //   curl 'http://127.0.0.1:8787/__scheduled?cron=*/5+*+*+*+*'
  //
  // Tip: ALWAYS call ctx.waitUntil on long-running work so the
  // Workers runtime keeps the isolate alive past the dispatcher's
  // synchronous return. The Ruby helper `wait_until(promise)` does
  // exactly that.
  async scheduled(event, env, ctx) {
    const dispatch = globalThis.__HOMURABI_SCHEDULED_DISPATCH__;
    if (typeof dispatch !== "function") {
      // No Ruby dispatcher installed — the Opal bundle didn't
      // require 'cloudflare_workers/scheduled'. Log loudly so this
      // misconfiguration surfaces instead of silently dropping
      // every cron firing.
      try {
        globalThis.console.error(
          "homurabi: scheduled dispatcher not installed (require 'cloudflare_workers/scheduled' missing)",
        );
      } catch (e) {
        // ignore — console may itself be broken in pathological cases
      }
      return;
    }

    // Hand the work to ctx.waitUntil so an async Ruby dispatcher
    // (D1 writes, KV writes, fetch calls) can finish even though
    // `scheduled` returns a Promise the runtime may not fully await
    // on its own.
    const work = (async () => {
      try {
        return await dispatch(event, env, ctx);
      } catch (err) {
        try {
          globalThis.console.error("[scheduled] dispatcher threw:", err && err.stack || err);
        } catch (e) {
          // ignore
        }
      }
    })();
    ctx.waitUntil(work);
    return work;
  },

  // Phase 11B — Cloudflare Queues consumer entry point.
  //
  // The Workers runtime invokes this `queue` export once per batch
  // for every `[[queues.consumers]]` entry in wrangler.toml. The
  // Ruby side registers handlers through the `consume_queue
  // 'queue-name' do |batch| ... end` DSL (lib/sinatra/queue.rb);
  // `globalThis.__HOMURABI_QUEUE_DISPATCH__` walks `batch.queue`
  // against those handlers and runs whichever matches. A bad handler
  // doesn't crash the consumer — errors are caught and logged so
  // sibling handlers still run.
  async queue(batch, env, ctx) {
    const dispatch = globalThis.__HOMURABI_QUEUE_DISPATCH__;
    if (typeof dispatch !== "function") {
      try {
        globalThis.console.error(
          "homurabi: queue dispatcher not installed (require 'cloudflare_workers/queue' missing)",
        );
      } catch (e) {}
      return;
    }
    const work = (async () => {
      try {
        return await dispatch(batch, env, ctx);
      } catch (err) {
        try {
          globalThis.console.error("[queue] dispatcher threw:", err && err.stack || err);
        } catch (e) {}
      }
    })();
    ctx.waitUntil(work);
    return work;
  },
};

// ---------------------------------------------------------------------
// Phase 11B — Durable Objects entry point.
//
// Every DO class listed in wrangler.toml's `[[durable_objects.bindings]]`
// must be a named export on this module. We export ONE generic class
// (`HomurabiCounterDO`) that forwards every `fetch(req)` it receives
// to the Ruby-side dispatcher installed by
// `lib/cloudflare_workers/durable_object.rb`
// (`globalThis.__HOMURABI_DO_DISPATCH__`).
//
// The Ruby handler is registered via:
//
//   Cloudflare::DurableObject.define('HomurabiCounterDO') do |state, req|
//     ...
//   end
//
// Keep this JS class as minimal as possible — every piece of DO logic
// lives in Ruby. When a new DO class is needed in a later phase, add
// another exported class next to this one with the same dispatcher
// forwarding and a different `class_name` argument.
// ---------------------------------------------------------------------

async function __homurabiForwardDO(class_name, state, env, request) {
  // Pre-await the request body so the Ruby dispatcher (which runs
  // synchronously under Opal) can read it without its own await. Keep
  // the read cheap — skip for bodyless methods.
  const m = (request && request.method ? request.method.toUpperCase() : "GET");
  let bodyText = "";
  if (m !== "GET" && m !== "HEAD" && m !== "OPTIONS") {
    try { bodyText = await request.text(); } catch (_e) { bodyText = ""; }
  }
  const dispatch = globalThis.__HOMURABI_DO_DISPATCH__;
  if (typeof dispatch !== "function") {
    return new Response(
      JSON.stringify({ error: "homurabi: DO dispatcher not installed" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }
  return await dispatch(class_name, state, env, request, bodyText);
}

export class HomurabiCounterDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }
  async fetch(request) {
    // Upgrade path: if the request asks for a WebSocket, accept one
    // end of a new pair via the Hibernation API and hand the other
    // end back to the client as part of a 101 response. After this,
    // the runtime dispatches any subsequent frames on the server
    // socket through the `webSocketMessage` / `webSocketClose` /
    // `webSocketError` methods below (which forward to Ruby).
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      const pair = new WebSocketPair();
      // The server end hibernates with the DO; tag it with the path
      // so Ruby handlers can filter.
      let url;
      try { url = new URL(request.url); } catch (_e) { url = { pathname: "/" }; }
      const tag = "path:" + (url.pathname || "/");
      try {
        this.state.acceptWebSocket(pair[1], [tag]);
      } catch (_e) {
        // Runtimes without Hibernation API — fall back to accepting
        // manually AND attaching event listeners that forward frames
        // to the same Ruby-side dispatchers `webSocketMessage` /
        // `webSocketClose` / `webSocketError` use. Without these the
        // upgrade would succeed but messages would silently drop
        // (Copilot review PR #9, fourth pass).
        try { pair[1].accept(); } catch (_) {}
        const self = this;
        pair[1].addEventListener("message", async (ev) => {
          const fn = globalThis.__HOMURABI_DO_WS_MESSAGE__;
          if (typeof fn === "function") {
            try { await fn("HomurabiCounterDO", pair[1], ev.data, self.state, self.env); } catch (_) {}
          }
        });
        pair[1].addEventListener("close", async (ev) => {
          const fn = globalThis.__HOMURABI_DO_WS_CLOSE__;
          if (typeof fn === "function") {
            try { await fn("HomurabiCounterDO", pair[1], ev.code, ev.reason, ev.wasClean, self.state, self.env); } catch (_) {}
          }
        });
        pair[1].addEventListener("error", async (ev) => {
          const fn = globalThis.__HOMURABI_DO_WS_ERROR__;
          if (typeof fn === "function") {
            try { await fn("HomurabiCounterDO", pair[1], ev, self.state, self.env); } catch (_) {}
          }
        });
      }
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return __homurabiForwardDO("HomurabiCounterDO", this.state, this.env, request);
  }

  // Hibernation API callbacks — routed into Ruby via the hooks
  // installed by `lib/cloudflare_workers/durable_object.rb`. Each
  // hook is optional on the Ruby side; missing hooks are a no-op.
  async webSocketMessage(ws, message) {
    const fn = globalThis.__HOMURABI_DO_WS_MESSAGE__;
    if (typeof fn === "function") {
      return fn("HomurabiCounterDO", ws, message, this.state, this.env);
    }
  }
  async webSocketClose(ws, code, reason, wasClean) {
    const fn = globalThis.__HOMURABI_DO_WS_CLOSE__;
    if (typeof fn === "function") {
      return fn("HomurabiCounterDO", ws, code, reason, wasClean, this.state, this.env);
    }
  }
  async webSocketError(ws, err) {
    const fn = globalThis.__HOMURABI_DO_WS_ERROR__;
    if (typeof fn === "function") {
      return fn("HomurabiCounterDO", ws, err, this.state, this.env);
    }
  }
}
