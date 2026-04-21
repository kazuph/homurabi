// Cloudflare Workers Module Worker — thin bootstrap (Phase 15-E).
// Order: node:crypto shim → Opal bundle side effects → Rack/Queue/DO handlers.
//
// Prefer `build/worker.entrypoint.mjs` as wrangler `main` in application repos;
// this file remains valid for monorepo layouts that point `main` at the gem path.

import "./setup-node-crypto.mjs";
import "../../../build/hello.no-exit.mjs";
export { default, HomurabiCounterDO } from "./worker_module.mjs";
