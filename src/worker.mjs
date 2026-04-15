// homurabi Phase 0: minimal CF Workers Module Worker that imports an
// Opal-compiled Ruby program. The success criteria are:
//   1. The import does not throw (Opal runtime loads on V8).
//   2. The Ruby `puts` runs at module init time and reaches the host
//      side via the lib/cloudflare_workers.rb adapter, which mirrors
//      every emitted line into globalThis.__HOMURABI_OUTPUT__.
//   3. The fetch handler returns 200 with diagnostic info AND the
//      captured Ruby output, so the response itself proves that the
//      pure-Ruby `puts "hello from real ruby on opal"` executed on
//      production CF Workers V8.
//
// Phase 0 still does not expose Ruby code as a request handler — that
// is Phase 1's job (the Sinatra DSL adapter).

import "../build/hello.no-exit.mjs";

export default {
  async fetch(request, env, ctx) {
    const opalLoaded = typeof globalThis.Opal !== "undefined";
    const url = new URL(request.url);
    const rubyOutput = Array.isArray(globalThis.__HOMURABI_OUTPUT__)
      ? globalThis.__HOMURABI_OUTPUT__.slice()
      : [];
    const sawHello = rubyOutput.some(
      (e) => e && typeof e.text === "string" && e.text.includes("hello from real ruby on opal"),
    );

    const body = {
      phase: "0",
      goal: "prove Opal-compiled Ruby loads on Cloudflare Workers V8 isolate",
      opal_loaded: opalLoaded,
      ruby_module: "app/hello.rb compiled via Opal 1.8.3.rc1 with --esm --no-source-map -E -I lib -r cloudflare_workers",
      ruby_puts_executed: sawHello,
      ruby_output: rubyOutput,
      path: url.pathname,
      timestamp: new Date().toISOString(),
    };

    return new Response(JSON.stringify(body, null, 2) + "\n", {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  },
};
