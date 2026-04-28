---
name: homura-workers-gems
description: Use this when asked how to use homura, opal-homura, homura-runtime, sinatra-homura, or sequel-d1, or when building Sinatra on Cloudflare Workers with this stack.
license: MIT
---

# homura Workers gem guide

Use this skill when the task is about:

- choosing which homura gem to install
- setting up Sinatra on Cloudflare Workers
- using D1 through Sequel
- building with `homura build`
- understanding common Opal/Workers gotchas in this stack

## Read these companion files first

- `gem-map.md` — which gem owns which responsibility
- `quick-start.md` — minimal install/build flow
- `gotchas.md` — mistakes that repeatedly trip up agents

## Package map

The published packages are:

1. `opal-homura` — patched Opal fork. Keep `require: 'opal'`.
2. `homura-runtime` — core runtime, Rack adapter, Workers bindings, build pipeline.
3. `sinatra-homura` — Sinatra integration, patches, JWT / Scheduled / Queue helpers, scaffolder.
4. `sequel-d1` — D1 adapter and migration compiler for Sequel.

Rule of thumb:

- If the question is about **build / worker bootstrap / bindings / Rack**, start with `homura-runtime`.
- If the question is about **routes / Sinatra DSL / JWT / cron / queue / scaffolding**, start with `sinatra-homura`.
- If the question is about **`Sequel.connect(adapter: :d1, ...)` or migrations**, start with `sequel-d1`.
- If the question is about **Opal compatibility or `require 'opal'`**, start with `opal-homura`.

## Minimal install order

When explaining setup, prefer the published gem names and this order:

1. `opal-homura`
2. `homura-runtime`
3. `sinatra-homura`
4. `sequel-d1` (optional)

## Output expectations

When generating guidance or code:

- use the **published gem names** only
- prefer the modern scaffold flow: `bundle exec homura new ...` then `bundle exec rake dev|build|deploy`
- for `--with-db` apps, include the generated `bundle exec rake db:migrate:compile|local|remote` flow
- point users at `bundle exec homura build` only for lower-level wiring or debugging
- assume generated apps use `wrangler.toml` `main = "build/worker.entrypoint.mjs"` plus `compatibility_flags = ["nodejs_compat"]`
- point users to `README.md`, `/llms.txt`, and this skill's companion files for current guidance
- keep examples sync-shaped unless a raw Promise boundary truly forces manual `.__await__`
- never emit `cloudflare-workers-*` command names or migration-first/legacy guidance in fresh answers
