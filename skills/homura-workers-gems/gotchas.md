# Gotchas

## Published names vs old internal names

Prefer:

- `homura-runtime`
- `sinatra-homura`
- `sequel-d1`
- `opal-homura`

Do not introduce the old names in fresh guidance unless explicitly explaining history.

## Async Sinatra routes

In this repo's Opal-on-Workers runtime:

- `halt` / `throw :halt` is unsafe across async boundaries
- in async flows, prefer returning values or `[status, body]`

## D1 / Sequel

- `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`
- `Dataset#all` resolves asynchronously on Workers, so examples often need `.__await__`

## Build output

- the Worker entrypoint is `build/worker.entrypoint.mjs`
- `bundle exec cloudflare-workers-build` is the standard build command

## Bindings

Bindings are exposed in Rack env under keys like:

- `env['cloudflare.DB']`
- `env['cloudflare.KV']`
- `env['cloudflare.BUCKET']`
- `env['cloudflare.AI']`

Use those names in examples instead of inventing new wrapper APIs.
