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
    //
    // Phase 11A: multipart/form-data bodies MUST be read as bytes, not
    // as UTF-8 text, or file uploads get mangled the moment any byte
    // outside the ASCII range appears. Use `arrayBuffer()` and convert
    // to a latin1 String (1 char = 1 byte) so Opal keeps the bytes
    // intact. `Cloudflare::Multipart.parse` decodes that back into an
    // UploadedFile whose `#to_uint8_array` returns a real Uint8Array
    // suitable for R2.put / fetch body.
    let bodyText = "";
    const method = request.method.toUpperCase();
    if (method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
      try {
        const contentType = request.headers.get("content-type") || "";
        if (contentType.toLowerCase().includes("multipart/")) {
          const buf = await request.arrayBuffer();
          bodyText = binaryArrayBufferToLatin1String(buf);
        } else {
          bodyText = await request.text();
        }
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
};
