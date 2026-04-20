// Phase 7 — bootstrap that exposes node:crypto on globalThis so the
// Opal-compiled Ruby bundle can use synchronous hash / hmac / cipher /
// pkey / kdf APIs without async/await glue.
//
// Cloudflare Workers exposes node:crypto when `compatibility_flags`
// includes "nodejs_compat" (already enabled in wrangler.toml). Node
// itself ships node:crypto natively, so the same import works in:
//
//   - Production (Cloudflare Workers + nodejs_compat)
//   - Test (Node.js, via `node --import ./gems/cloudflare-workers-runtime/runtime/setup-node-crypto.mjs`)
//
// Why globalThis: Opal-emitted ESM modules cannot easily declare new
// `import` statements after the build. Setting a global lets every
// Ruby code path reach the same crypto module via a single backtick:
//
//   `globalThis.__nodeCrypto__.createHash('sha256')`

import nodeCrypto from "node:crypto";

globalThis.__nodeCrypto__ = nodeCrypto;
