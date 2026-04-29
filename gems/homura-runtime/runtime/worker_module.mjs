// Rack / Cron / Queue / DO adapters for Cloudflare Workers (no Opal bundle import).
// Load order: setup-node-crypto.mjs → Opal bundle (side effects) → this module.
// Phase 15-E: split from worker.mjs so generated worker.entrypoint.mjs can use
// fixed relative imports to the build artifact.

// ---------------------------------------------------------------------------
// Phase 15-A — dispatch resolution: prefer __OPAL_WORKERS__, alias legacy
// ---------------------------------------------------------------------------

function rackDispatch() {
  const ow = globalThis.__OPAL_WORKERS__;
  const fn = ow && typeof ow.rack === "function" ? ow.rack : undefined;
  return fn || globalThis.__HOMURA_RACK_DISPATCH__;
}

/** Phase 17 — Workers `env.SEND_EMAIL` を Rack 構築より前に global に載せ、Miniflare でも Ruby が同じバインディングを拾えるようにする。 */
function ensureOpalWorkersEmailBinding(env) {
  const ow = (globalThis.__OPAL_WORKERS__ ||= {});
  if (env && env.SEND_EMAIL) {
    ow.sendEmailBinding = env.SEND_EMAIL;
  }
}

/**
 * Miniflare の entry.worker は `/cdn-cgi/mf/scheduled` だけ先に処理する。
 * `/cdn-cgi/handler/email` 等はユーザ Worker の fetch に届くため、ここで Rack に渡さず処理する。
 * （Cloudflare Email Routing — Local Development の受信スタブ向け。Phase 18 で `email()` と接続予定）
 */
async function handleCdnCgiBypass(request, env, _ctx) {
  const url = new URL(request.url);
  if (url.pathname === "/cdn-cgi/handler/email") {
    if (request.method === "POST") {
      try {
        globalThis.console.log(
          "[homura] POST /cdn-cgi/handler/email — bypass Rack (Email Routing local-dev stub path)",
        );
      } catch (_e) {}
      return new Response(
        JSON.stringify({
          ok: true,
          bypass: "rack",
          pathname: url.pathname,
          note: "homura worker_module forwards /cdn-cgi away from Sinatra. Full inbound handling: Phase 18 (export email()).",
        }),
        { status: 200, headers: { "content-type": "application/json; charset=utf-8" } },
      );
    }
    return new Response("Method Not Allowed", { status: 405 });
  }
  if (env.ASSETS && typeof env.ASSETS.fetch === "function") {
    return env.ASSETS.fetch(request);
  }
  return new Response("not handled", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
}

function scheduledDispatch() {
  const ow = globalThis.__OPAL_WORKERS__;
  const fn = ow && typeof ow.scheduled === "function" ? ow.scheduled : undefined;
  return fn || globalThis.__HOMURA_SCHEDULED_DISPATCH__;
}

function queueDispatch() {
  const ow = globalThis.__OPAL_WORKERS__;
  const fn = ow && typeof ow.queue === "function" ? ow.queue : undefined;
  return fn || globalThis.__HOMURA_QUEUE_DISPATCH__;
}

function durableObjectDispatch() {
  const d = globalThis.__OPAL_WORKERS__ && globalThis.__OPAL_WORKERS__.durableObject;
  const fn = d && typeof d.dispatch === "function" ? d.dispatch : undefined;
  return fn || globalThis.__HOMURA_DO_DISPATCH__;
}

function durableObjectWsMessage() {
  const d = globalThis.__OPAL_WORKERS__ && globalThis.__OPAL_WORKERS__.durableObject;
  const fn = d && typeof d.wsMessage === "function" ? d.wsMessage : undefined;
  return fn || globalThis.__HOMURA_DO_WS_MESSAGE__;
}

function durableObjectWsClose() {
  const d = globalThis.__OPAL_WORKERS__ && globalThis.__OPAL_WORKERS__.durableObject;
  const fn = d && typeof d.wsClose === "function" ? d.wsClose : undefined;
  return fn || globalThis.__HOMURA_DO_WS_CLOSE__;
}

function durableObjectWsError() {
  const d = globalThis.__OPAL_WORKERS__ && globalThis.__OPAL_WORKERS__.durableObject;
  const fn = d && typeof d.wsError === "function" ? d.wsError : undefined;
  return fn || globalThis.__HOMURA_DO_WS_ERROR__;
}

// Phase 11A — binary-safe body passthrough. Convert an ArrayBuffer of
// request body bytes into a latin1 String (each code unit 0–255 is
// exactly one byte). Opal Strings are JS Strings (UTF-16), but a
// latin1-encoded string survives through StringIO / Ruby unchanged.
// The Ruby side (`Cloudflare::Multipart`) reads those bytes and, for
// file parts, converts them back to a real Uint8Array when passing
// to R2.put / fetch body.
//
// Chunked to avoid the `Maximum call stack size exceeded` hazard of
// `String.fromCharCode.apply(null, hugeArray)` — the ~0xFFFE arg cap
// differs per engine, so we stay comfortably below at 0x8000.
function binaryArrayBufferToLatin1String(arrayBuffer) {
  const u8 = new Uint8Array(arrayBuffer);
  const CHUNK = 0x8000;
  // Accumulate into an array and join once at the end — in-loop
  // String concatenation is O(n²) on V8 for large uploads. Each
  // `chunk` here is already a small String (≤ 32768 chars), so
  // join() can reuse rope structures efficiently.
  const parts = [];
  for (let i = 0; i < u8.length; i += CHUNK) {
    const slice = u8.subarray(i, Math.min(i + CHUNK, u8.length));
    parts.push(String.fromCharCode.apply(null, slice));
  }
  return parts.join("");
}

// Module Worker `fetch` and Durable Object HTTP `fetch` must use the same body
// semantics: multipart/form-data uses arrayBuffer + latin1 (Phase 11A), not UTF-8 text().
async function readBodyTextForRubyDispatcher(request) {
  const method = (request && request.method ? request.method : "GET").toUpperCase();
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") {
    return { bodyText: "" };
  }
  try {
    const contentType = request.headers.get("content-type") || "";
    if (contentType.toLowerCase().includes("multipart/")) {
      const buf = await request.arrayBuffer();
      return { bodyText: binaryArrayBufferToLatin1String(buf) };
    }
    return { bodyText: await request.text() };
  } catch (err) {
    return {
      bodyReadError: new Response(
        JSON.stringify({ error: "failed to read request body", detail: err.message }),
        { status: 400, headers: { "content-type": "application/json" } },
      ),
    };
  }
}

export default {
  async fetch(request, env, ctx) {
    ensureOpalWorkersEmailBinding(env);

    let reqUrl;
    try {
      reqUrl = new URL(request.url);
    } catch (_e) {
      reqUrl = { pathname: "/" };
    }
    if (reqUrl.pathname.startsWith("/cdn-cgi/")) {
      return handleCdnCgiBypass(request, env, ctx);
    }

    const dispatch = rackDispatch();
    if (typeof dispatch !== "function") {
      return new Response(
        "homura: Rack dispatcher not installed (Rack::Handler::Homura.run never called)\n",
        { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }

    // Read the body here while we still have the async context. The Opal
    // side runs synchronous Ruby, so it cannot `await req.text()` inside
    // the dispatcher. For methods that are defined to have no body
    // (GET, HEAD, OPTIONS by spec) we skip the read entirely to avoid
    // wasting a round-trip.
    //
    const bodyResult = await readBodyTextForRubyDispatcher(request);
    if (bodyResult.bodyReadError) {
      return bodyResult.bodyReadError;
    }

    return dispatch(request, env, ctx, bodyResult.bodyText);
  },

  // Phase 9 — Cloudflare Workers Cron Triggers entry point.
  //
  // The Workers runtime invokes this `scheduled` export once per
  // matching `[triggers] crons` entry in wrangler.toml. We forward
  // the (event, env, ctx) triple to the Ruby-side dispatcher
  // installed by `lib/homura/runtime/scheduled.rb`
  // (which registers `globalThis.__HOMURA_SCHEDULED_DISPATCH__`).
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
    const dispatch = scheduledDispatch();
    if (typeof dispatch !== "function") {
      // No Ruby dispatcher installed — the Opal bundle didn't
      // require 'homura/runtime/scheduled'. Log loudly so this
      // misconfiguration surfaces instead of silently dropping
      // every cron firing.
      try {
        globalThis.console.error(
          "homura: scheduled dispatcher not installed (require 'homura/runtime/scheduled' missing)",
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
  // `globalThis.__HOMURA_QUEUE_DISPATCH__` walks `batch.queue`
  // against those handlers and runs whichever matches. A bad handler
  // doesn't crash the consumer — errors are caught and logged so
  // sibling handlers still run.
  async queue(batch, env, ctx) {
    const dispatch = queueDispatch();
    if (typeof dispatch !== "function") {
      try {
        globalThis.console.error(
          "homura: queue dispatcher not installed (require 'homura/runtime/queue' missing)",
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
// (`HomuraCounterDO`) that forwards every `fetch(req)` it receives
// to the Ruby-side dispatcher installed by
// `lib/homura/runtime/durable_object.rb`
// (`globalThis.__HOMURA_DO_DISPATCH__`).
//
// The Ruby handler is registered via:
//
//   Cloudflare::DurableObject.define('HomuraCounterDO') do |state, req|
//     ...
//   end
//
// Keep this JS class as minimal as possible — every piece of DO logic
// lives in Ruby. When a new DO class is needed in a later phase, add
// another exported class next to this one with the same dispatcher
// forwarding and a different `class_name` argument.
// ---------------------------------------------------------------------

async function __homuraForwardDO(class_name, state, env, request) {
  // Pre-await the request body so the Ruby dispatcher (which runs
  // synchronously under Opal) can read it without its own await.
  // Multipart uses the same byte-preserving path as Module Worker fetch (Phase 11A).
  const bodyResult = await readBodyTextForRubyDispatcher(request);
  if (bodyResult.bodyReadError) {
    return bodyResult.bodyReadError;
  }
  const bodyText = bodyResult.bodyText;
  const dispatch = durableObjectDispatch();
  if (typeof dispatch !== "function") {
    return new Response(
      JSON.stringify({ error: "homura: DO dispatcher not installed" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }
  return await dispatch(class_name, state, env, request, bodyText);
}

export class HomuraCounterDO {
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
          const fn = durableObjectWsMessage();
          if (typeof fn === "function") {
            try { await fn("HomuraCounterDO", pair[1], ev.data, self.state, self.env); } catch (_) {}
          }
        });
        pair[1].addEventListener("close", async (ev) => {
          const fn = durableObjectWsClose();
          if (typeof fn === "function") {
            try { await fn("HomuraCounterDO", pair[1], ev.code, ev.reason, ev.wasClean, self.state, self.env); } catch (_) {}
          }
        });
        pair[1].addEventListener("error", async (ev) => {
          const fn = durableObjectWsError();
          if (typeof fn === "function") {
            try { await fn("HomuraCounterDO", pair[1], ev, self.state, self.env); } catch (_) {}
          }
        });
      }
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return __homuraForwardDO("HomuraCounterDO", this.state, this.env, request);
  }

  // Hibernation API callbacks — routed into Ruby via the hooks
  // installed by `lib/homura/runtime/durable_object.rb`. Each
  // hook is optional on the Ruby side; missing hooks are a no-op.
  async webSocketMessage(ws, message) {
    const fn = durableObjectWsMessage();
    if (typeof fn === "function") {
      return fn("HomuraCounterDO", ws, message, this.state, this.env);
    }
  }
  async webSocketClose(ws, code, reason, wasClean) {
    const fn = durableObjectWsClose();
    if (typeof fn === "function") {
      return fn("HomuraCounterDO", ws, code, reason, wasClean, this.state, this.env);
    }
  }
  async webSocketError(ws, err) {
    const fn = durableObjectWsError();
    if (typeof fn === "function") {
      return fn("HomuraCounterDO", ws, err, this.state, this.env);
    }
  }
}
