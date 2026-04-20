# cloudflare-workers-runtime

**Phase 15-B** — Core Ruby + Module Worker glue for [Opal](https://opalrb.com/) on [Cloudflare Workers](https://developers.cloudflare.com/workers/). This gem does **not** depend on Sinatra or Sequel; those live in separate gems (homurabi roadmap Phase 15-C / 15-D).

## What you get

- `require 'opal_patches'` — additive patches for Opal corelib vs real-world gems (Rack, etc.).
- `require 'cloudflare_workers'` — `Rack::Handler::CloudflareWorkers`, `CloudflareWorkers.register_rack` / `register_scheduled` / `register_queue`, and `Cloudflare::D1Database`, `KVNamespace`, `R2Bucket`, `AI`, HTTP, multipart, cache, queue, durable object helpers.
- `runtime/worker.mjs` — Module Worker that prefers `globalThis.__OPAL_WORKERS__` and falls back to legacy `__HOMURABI_*` globals (see `docs/TOOLCHAIN_CONTRACT.md` in the homurabi repo).
- `runtime/setup-node-crypto.mjs` — exposes `node:crypto` on `globalThis` before the Opal bundle loads (matches Workers `nodejs_compat`).

## Minimal integration (Rack only, no Sinatra)

1. Add to your `Gemfile`:

   ```ruby
   gem 'opal', '~> 1.8.3.rc1'
   gem 'cloudflare-workers-runtime', path: 'gems/cloudflare-workers-runtime' # or git / rubygems later
   ```

2. Build an Opal ESM bundle that pre-requires patches and runtime:

   ```text
   bundle exec opal -c -E --esm --no-source-map \
     -I lib -I vendor -I build \
     -r opal_patches -r cloudflare_workers \
     -o build/app.mjs config.ru # or your entry
   ```

3. Point `wrangler.toml` at this gem’s worker and mirror the `import` path to your bundle (see homurabi’s `wrangler.toml` `main = "gems/cloudflare-workers-runtime/runtime/worker.mjs"` and the relative `../../../build/hello.no-exit.mjs` import inside `worker.mjs` for the monorepo layout).

4. For **Sinatra** on Workers, use the upcoming `sinatra-cloudflare-workers` gem (Phase 15-C) instead of wiring everything by hand.

## Wrangler template

See `runtime/wrangler.toml.example` for optional D1 / KV / R2 / AI / DO / Queue snippets (opt-in comments).

## License

Follow the license terms of the homurabi repository that vendors this gem.
