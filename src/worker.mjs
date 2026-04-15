// homurabi Phase 0: minimal CF Workers Module Worker that imports an
// Opal-compiled Ruby program. The success criterion is:
//   1. The import does not throw (Opal runtime loads on V8).
//   2. The Ruby `puts` runs at module init time (visible in wrangler logs).
//   3. The fetch handler returns 200 with diagnostic info.
//
// Phase 0 does NOT yet expose Ruby code as a request handler — that is Phase 1.

import "../build/hello.no-exit.mjs";

export default {
  async fetch(request, env, ctx) {
    const opalLoaded = typeof globalThis.Opal !== "undefined";
    const opalVersion = opalLoaded ? globalThis.Opal.version : null;
    const url = new URL(request.url);

    const body = {
      phase: "0",
      goal: "prove Opal-compiled Ruby loads on Cloudflare Workers V8 isolate",
      opal_loaded: opalLoaded,
      opal_version: opalVersion,
      ruby_module: "app/hello.rb compiled via Opal 1.8.3.rc1 with --esm --no-source-map -E",
      path: url.pathname,
      timestamp: new Date().toISOString(),
    };

    return new Response(JSON.stringify(body, null, 2) + "\n", {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  },
};
