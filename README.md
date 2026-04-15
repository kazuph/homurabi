# homurabi

**Real Ruby + Sinatra on Cloudflare Workers via Opal**

Sister project of [`kazuph/homura`](https://github.com/kazuph/homura) (mruby/WASI version).

`homurabi` aims to run **the actual `janbiedermann/sinatra` fork** on Cloudflare Workers by compiling Ruby source code with [Opal](https://opalrb.com) (Ruby → JavaScript compiler) and shipping the result as an ESM Module Worker.

## Status

🚧 **Phase 0: Baseline verification** — see [`.artifacts/homurabi/PLAN.md`](.artifacts/homurabi/PLAN.md) for the strict implementation plan.

## Goal (Definition of Done)

- [ ] `app.rb` written in real CRuby syntax with `require 'sinatra'` and Sinatra DSL
- [ ] Compiled to ESM via Opal and bundled into a Cloudflare Workers Module Worker
- [ ] Real `janbiedermann/sinatra` fork (no DSL re-implementation, no compatibility layer fakes)
- [ ] D1 / KV / R2 bindings callable from Sinatra routes via Opal's `Native` module
- [ ] `wrangler dev` and `wrangler deploy` both serve the Sinatra app

## Strict policy

This project enforces a **no-fallback** policy. The means **is** the goal: the entire point is to run real Ruby + real Sinatra + real Opal on real Cloudflare Workers. Any deviation that "just makes it work" (e.g. swapping in a Sinatra-compatible DSL, falling back to mruby, switching to Cloudflare Containers, etc.) results in immediate rejection of that phase's deliverables.

See [`.artifacts/homurabi/PLAN.md`](.artifacts/homurabi/PLAN.md) for the full plan and forbidden-fallback list.

## Sister project

- [`kazuph/homura`](https://github.com/kazuph/homura) — Hono-like Ruby DSL on mruby/WASI for Cloudflare Workers (lightweight, custom DSL, proven to work)
- [`kazuph/homurabi`](https://github.com/kazuph/homurabi) — this repo, real Ruby + real Sinatra via Opal (ambitious, fallback-forbidden)

## License

TBD
