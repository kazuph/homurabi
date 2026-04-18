#!/usr/bin/env node
// Phase 11A — rewrite Opal runtime `eval(...)` calls to `globalThis.eval(...)`.
//
// The Opal stdlib includes an `eval` / `require_remote` code path used
// only for interactive / IRB scenarios (Opal.compile → eval at
// runtime). On Workers we pre-compile every .rb file at build time, so
// those eval sites never actually fire. esbuild still sees them
// lexically and emits a "direct eval" warning (which wrangler echoes
// as red `ERROR` rows). The calls are semantically identical to
// `globalThis.eval(...)` in these positions (they don't depend on the
// enclosing lexical scope), and `globalThis.eval` is the
// spec-blessed way to ask for indirect eval — which esbuild doesn't
// warn about.
//
// This script is invoked as a post-opal step by `npm run build:opal`
// (via the build pipeline). Runs fast (single regex pass) and is
// idempotent (re-running on already-patched output is a no-op).
//
// We match `eval(` only when preceded by a non-identifier character
// so we don't rewrite `Kernel#$eval`, `instance_eval`, `module_eval`,
// `self.$eval`, etc. — those are property accesses / method names,
// not the global function.

import { readFileSync, writeFileSync } from 'node:fs';

const path = process.argv[2] || 'build/hello.no-exit.mjs';
const src = readFileSync(path, 'utf8');

// Boundary class: must not be [.$a-zA-Z0-9_]. We include
// `\b(?<!globalThis\.)` negative lookbehind isn't supported everywhere,
// so we instead do a two-step: first replace `(^|[^...])eval(` then
// revert any accidental double-rewrite of `globalThis.eval(`.
const before = /(^|[^.$a-zA-Z0-9_])eval\(/gm;
const after  = '$1globalThis.eval(';
let out = src.replace(before, after);

// Guard against accidental `globalThis.globalThis.eval(` if this script
// is run twice (defensive — replace() above is already idempotent
// because `.globalThis.eval(` starts with `.` which fails the
// boundary, but belt-and-suspenders).
out = out.replace(/globalThis\.globalThis\.eval\(/g, 'globalThis.eval(');

const changes = (out.match(/globalThis\.eval\(/g) || []).length;
if (out === src) {
  console.log(`[patch-opal-evals] no changes needed (${path})`);
} else {
  writeFileSync(path, out);
  console.log(`[patch-opal-evals] rewrote ${changes} direct eval → globalThis.eval (${path})`);
}
