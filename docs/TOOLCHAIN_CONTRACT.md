# Toolchain contract (Phase 15-A)

This document is the **interface specification** between the Cloudflare
Workers module worker (`src/worker.mjs`), the Opal compile flags, and the
build artifacts. Downstream gem splits (Phase 15-B/C) should preserve these
contracts unless explicitly versioned.

## 1. JavaScript ↔ Ruby dispatch (`globalThis`)

### 1.1 Legacy hooks (still installed — backward compatible)

| Global | Producer (Ruby) | Consumer (`src/worker.mjs`) |
|--------|-----------------|------------------------------|
| `__HOMURABI_RACK_DISPATCH__` | `Rack::Handler::CloudflareWorkers.install_dispatcher` | `fetch()` |
| `__HOMURABI_SCHEDULED_DISPATCH__` | `Cloudflare::Scheduled.install_dispatcher` | `scheduled()` |
| `__HOMURABI_QUEUE_DISPATCH__` | `Cloudflare::QueueConsumer.install_dispatcher` | `queue()` |
| `__HOMURABI_DO_DISPATCH__` | `Cloudflare::DurableObject.install_dispatcher` | DO `fetch()` |
| `__HOMURABI_DO_WS_{MESSAGE,CLOSE,ERROR}__` | same | DO WebSocket hibernation |

### 1.2 Canonical namespace (Phase 15-A)

`globalThis.__OPAL_WORKERS__` is an object populated **after** each legacy
global is assigned. The Ruby installers mirror the same function references:

| Key path | Maps from |
|----------|-----------|
| `__OPAL_WORKERS__.rack` | `__HOMURABI_RACK_DISPATCH__` |
| `__OPAL_WORKERS__.scheduled` | `__HOMURABI_SCHEDULED_DISPATCH__` |
| `__OPAL_WORKERS__.queue` | `__HOMURABI_QUEUE_DISPATCH__` |
| `__OPAL_WORKERS__.durableObject.dispatch` | `__HOMURABI_DO_DISPATCH__` |
| `__OPAL_WORKERS__.durableObject.wsMessage` | `__HOMURABI_DO_WS_MESSAGE__` |
| `__OPAL_WORKERS__.durableObject.wsClose` | `__HOMURABI_DO_WS_CLOSE__` |
| `__OPAL_WORKERS__.durableObject.wsError` | `__HOMURABI_DO_WS_ERROR__` |

The worker **prefers** `__OPAL_WORKERS__` and **falls back** to the legacy
globals so older smoke bundles and gradual migrations keep working.

## 2. Opal compile flags (app bundle)

Homurabi’s production bundle is built with:

- `-I lib -I vendor -I build`
- `-r opal_patches -r cloudflare_workers -r homurabi_templates -r homurabi_assets`
- Entry: `app/hello.rb` (overridable)
- Output: `build/hello.no-exit.mjs` (overridable)

### Environment overrides (`npm run build:opal`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `HOMURABI_OPAL_INPUT` | `app/hello.rb` | Opal entry file |
| `HOMURABI_OPAL_OUTPUT` | `build/hello.no-exit.mjs` | ESM bundle path |
| `HOMURABI_OPAL_PATCH_INPUT` | same as `HOMURABI_OPAL_OUTPUT` | Target for `bin/patch-opal-evals.mjs` |

Post-step: `node bin/patch-opal-evals.mjs [--input PATH]` rewrites direct
`eval(` → `globalThis.eval(` for Workers compliance.

## 3. ERB precompile (`bin/compile-erb`)

| Flag | Default | |
|------|---------|--|
| `--input` | `views` | Directory scanned for `*.erb` |
| `--output` | `build/homurabi_templates.rb` | Generated Ruby module file |
| `--namespace` | `HomurabiTemplates` | Ruby module name |

The Opal build must `-r` the **basename** of the output file (without `.rb`):
e.g. `-r homurabi_templates` when output is `build/homurabi_templates.rb`.

Legacy: pass explicit `.erb` paths without `--output` to emit the combined
Ruby to **stdout** (used by ad-hoc debugging).

## 4. Static assets (`bin/compile-assets`)

| Flag | Default |
|------|---------|
| `--input` | `public` |
| `--output` | `build/homurabi_assets.rb` |
| `--namespace` | `HomurabiAssets` |

Opal requires `-r homurabi_assets` when using the default output name.

## 5. Rake orchestration

`rake build` runs `build:erb`, `build:assets`, and `build:opal` in order.
Use plain `rake` (not `bundle exec rake`) unless `rake` is added to the
`Gemfile` — Bundler does not currently ship `rake` for this app.

## 6. Wrangler bindings (reference)

`wrangler.toml` declares D1, KV, R2, AI, Queues, Durable Objects, etc.
`lib/cloudflare_workers.rb` maps `env.DB` / `env.KV` / … onto
`env['cloudflare.*']` keys. Changing binding **names** requires coordinated
updates in Ruby + TOML — out of scope for Phase 15-A but listed here because
gem consumers will copy the pattern.
