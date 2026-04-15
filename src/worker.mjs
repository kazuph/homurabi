// homurabi Phase 1: ESM Module Worker that delegates fetch handling
// entirely to Ruby code compiled by Opal.
//
// The imported bundle (build/hello.no-exit.mjs) installs the
// `globalThis.__HOMURABI_HANDLE__` dispatcher via lib/cloudflare_workers.rb's
// Homurabi.handle block. We forward every fetch to that dispatcher and
// return whatever JS Response the Ruby handler produces.
//
// JS-side surface area is intentionally tiny: no routing, no formatting,
// no framework — the response is composed entirely on the Ruby side.

import "../build/hello.no-exit.mjs";

export default {
  async fetch(request, env, ctx) {
    const dispatch = globalThis.__HOMURABI_HANDLE__;
    if (typeof dispatch !== "function") {
      return new Response(
        "homurabi: __HOMURABI_HANDLE__ not installed (Homurabi.handle was never called)\n",
        { status: 500, headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }
    return dispatch(request, env, ctx);
  },
};
