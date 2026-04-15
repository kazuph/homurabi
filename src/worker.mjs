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
    return dispatch(request, env, ctx);
  },
};
