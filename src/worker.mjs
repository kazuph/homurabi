// Cloudflare Workers Module Worker that hosts a pure Rack application
// compiled from Ruby by Opal. The Ruby side is a regular Rack app that
// would also run on Puma, Unicorn, etc.; this file is the Rack server
// adapter on the JavaScript side.
//
// The imported bundle (build/hello.no-exit.mjs) installs
// `globalThis.__HOMURABI_RACK_DISPATCH__` via lib/cloudflare_workers.rb's
// Rack::Handler::CloudflareWorkers. We forward every fetch event through
// it and return whatever JS Response the Ruby Rack app produced.

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
};
