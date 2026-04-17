# Phase 9 — Scheduled Workers (Cron Triggers) — REPORT

> **Status: shipped (worktree feature/phase9-cron, ready for PR to main)**
> Branch: `feature/phase9-cron`
> Tests: 27 (smoke) + 14 (http) + 85 (crypto) + 43 (jwt) + **29 (scheduled, NEW)** = **198 total, all green**
> Build: `5.6 MB` `build/hello.no-exit.mjs` (essentially flat vs Phase 8)

## What ships

A Sinatra-style `schedule '*/5 * * * *' do |event| ... end` DSL that wires
straight into the Cloudflare Workers `scheduled(event, env, ctx)` lifecycle.
The block runs in a fresh `Sinatra::Scheduled::ScheduledContext` instance
that exposes the same `db` / `kv` / `bucket` helpers as HTTP routes plus a
`wait_until(promise)` wrapper around `ctx.waitUntil`.

```ruby
class App < Sinatra::Base
  register Sinatra::Scheduled

  schedule '*/5 * * * *', name: 'heartbeat' do |event|
    db.execute_insert(
      'INSERT INTO heartbeats (cron, scheduled_at, fired_at, note) VALUES (?, ?, ?, ?)',
      [event.cron, event.scheduled_time.to_i, Time.now.to_i, 'phase9-heartbeat']
    ).__await__
  end

  schedule '0 */1 * * *', name: 'hourly-housekeeping' do |event|
    raw  = kv.get('cron:hourly-counter').__await__
    prev = raw ? JSON.parse(raw)['count'].to_i : 0
    kv.put('cron:hourly-counter', { 'count' => prev + 1, 'last_cron' => event.cron, ... }.to_json).__await__
  end
end
```

`wrangler.toml`:
```toml
[triggers]
crons = [
  "*/5 * * * *",   # heartbeat — writes a row to D1 every 5 minutes
  "0 */1 * * *",   # hourly housekeeping — KV cleanup demo
]
```

## Files added / changed

| Path | Status | Purpose |
|---|---|---|
| `lib/sinatra/scheduled.rb` | **new** | Sinatra extension — `schedule` DSL, `Job` registry, `dispatch_scheduled` class method, `ScheduledContext` runtime (`db`/`kv`/`bucket`/`wait_until`) |
| `lib/cloudflare_workers/scheduled.rb` | **new** | `Cloudflare::ScheduledEvent`, JS hook installer (`globalThis.__HOMURABI_SCHEDULED_DISPATCH__`), `dispatch_js` / `dispatch` / `await_promise` helpers |
| `lib/cloudflare_workers.rb` | edit | `require 'cloudflare_workers/scheduled'` |
| `src/worker.mjs` | edit | adds `scheduled(event, env, ctx)` export — forwards to `__HOMURABI_SCHEDULED_DISPATCH__`, wraps in `ctx.waitUntil(work)` |
| `app/hello.rb` | edit | registers `Sinatra::Scheduled`, demo `schedule` blocks (heartbeat → D1, hourly → KV), `/test/scheduled` & `/test/scheduled/run` introspection routes (gated by `HOMURABI_ENABLE_SCHEDULED_DEMOS`) |
| `wrangler.toml` | edit | `[triggers] crons = […]` example, `HOMURABI_ENABLE_SCHEDULED_DEMOS = "0"` default-deny gate |
| `bin/schema.sql` | edit | adds `heartbeats` table for the heartbeat cron demo |
| `test/scheduled_smoke.rb` | **new** | 29 tests — DSL, validation, dispatch, ScheduledContext, JS hook |
| `package.json` | edit | `build:scheduled-test` + `test:scheduled` scripts; `clean` updated; full `test` chain extended |
| `README.md` | edit | Phase 9 section under "Scheduled Workers" |

## Test coverage breakdown

`test/scheduled_smoke.rb` — **29 cases, 9 groups**:

1. **DSL registration (5)** — exact registration, cron capture, `:name` option,
   default name, multi-`schedule` accumulation
2. **Cron expression validation (5)** — empty string rejection, 4-field /
   7-field rejection, no-block rejection, 6-field acceptance
3. **Dispatch: exact-string match (4)** — only matching job fires,
   ScheduledEvent flows through, no-match returns `fired=0`, results record
   `name`/`cron`/`ok`
4. **ScheduledContext helpers (5)** — `#db` / `#kv` / `#bucket` / `#env`
   are defined; `env['cloudflare.cron']` and `env['cloudflare.scheduled']`
   are present; D1 / KV wrappers are constructed when bindings are set
5. **`Cloudflare::ScheduledEvent.from_js` (2)** — JS event → Ruby Time
   conversion, missing `scheduledTime` defaults to `Time.now`
6. **`Cloudflare::Scheduled.dispatch` (2)** — explicit `app=` route and
   no-app raise
7. **Custom `:match` proc (2)** — `match: ->(c) { true }` catches arbitrary
   crons; `match: ->(c) { false }` skips
8. **Per-job error isolation (2)** — sibling job survives an exception;
   error class + message captured in `results` array
9. **JS dispatcher hook (2)** — `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`
   is installed; full round-trip from JS hook → Sinatra dispatcher → block
   side effect

```text
$ npm test
27 tests, 27 passed, 0 failed   (smoke)
14 tests, 14 passed, 0 failed   (http)
85 tests, 85 passed, 0 failed   (crypto)
43 tests, 43 passed, 0 failed   (jwt)
29 tests, 29 passed, 0 failed   (scheduled — NEW)
```

## In-Worker (live `wrangler dev`) verification

Brought up `npx wrangler dev --test-scheduled --local` against a fresh
local D1 + KV. Both demo schedules fire end-to-end through
`worker.mjs#scheduled` → `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`
→ `Cloudflare::Scheduled.dispatch_js` → `Sinatra::Scheduled` → user block
→ live D1 / KV write.

### Workers runtime path (`/__scheduled?cron=…`)

```
$ curl 'http://127.0.0.1:8787/__scheduled?cron=*/5+*+*+*+*'
Ran scheduled event

$ wrangler d1 execute homurabi-db --local --command "SELECT COUNT(*) FROM heartbeats WHERE note='phase9-heartbeat';"
6  →  7   (incremented by 1 per firing)

$ curl 'http://127.0.0.1:8787/__scheduled?cron=0+*/1+*+*+*'
Ran scheduled event

$ curl http://127.0.0.1:8787/kv/cron:hourly-counter
{"key":"cron:hourly-counter","value":"{\"count\":7,\"last_cron\":\"0 */1 * * *\",\"last_run_at\":1776429651,\"last_sched_t\":1776429651}"}
```

### Self-test introspection (`/test/scheduled` + `/test/scheduled/run`)

`HOMURABI_ENABLE_SCHEDULED_DEMOS=1` (default-deny gate) flipped via
`.dev.vars`:

```json
$ curl http://127.0.0.1:8787/test/scheduled
{"jobs":[
  {"name":"heartbeat","cron":"*/5 * * * *","file":null,"line":null},
  {"name":"hourly-housekeeping","cron":"0 */1 * * *","file":null,"line":null}
]}

$ curl -X POST 'http://127.0.0.1:8787/test/scheduled/run?cron=*/5%20*%20*%20*%20*'
{"fired":1,"total":2,"results":[{"name":"heartbeat","cron":"*/5 * * * *","ok":true,"duration":0.003}],"cron":"*/5 * * * *","registered_crons":["*/5 * * * *","0 */1 * * *"]}

$ curl -X POST 'http://127.0.0.1:8787/test/scheduled/run?cron=99%20*%20*%20*%20*'
{"fired":0,"total":2,"results":[],"cron":"99 * * * *","registered_crons":["*/5 * * * *","0 */1 * * *"]}

$ # 4 manual hourly fires from a fresh KV → counter increments correctly
$ curl http://127.0.0.1:8787/kv/cron:hourly-counter
{"key":"cron:hourly-counter","value":"{\"count\":4,\"last_cron\":\"0 */1 * * *\", ...}"}
```

The non-zero `duration` (1–3 ms) and the actual D1 / KV state changes
prove the dispatcher truly waits for the inner `__await__` chain — i.e.
side effects complete before the dispatcher records `ok: true`.

## Production safety

`/test/scheduled` and `/test/scheduled/run` are gated by
`HOMURABI_ENABLE_SCHEDULED_DEMOS` (defaults to `"0"` in `wrangler.toml`),
so they 404 in production. The reasoning is identical to Phase 7's
`HOMURABI_ENABLE_CRYPTO_DEMOS`: `/test/scheduled/run` lets any
unauthenticated caller burn binding quota by manually firing every
registered cron. Flip to `"1"` only in dev or behind a private route.

The `scheduled(event, env, ctx)` runtime entry point is _not_ gated — it
is the legitimate Cloudflare runtime hook for declared cron triggers.

## Design decisions

### `define_method` instead of `instance_exec`

The first cut used `ctx.instance_exec(event, &job.block)` to run the
user block. That hit two showstoppers under Opal:

1. `instance_exec` is sync, so the block's `__await__` calls did not
   actually wait — KV / D1 writes silently fire-and-forget.
2. Exceptions raised inside the block became rejected Promises that
   our outer rescue could not catch — every job reported `ok: true`
   even when it threw.

Fix: convert the block to a method via `define_method` on
`ScheduledContext`, then call it via `unbound_method.bind(ctx).call`.
Opal's `# await: true` mode promotes `define_method`'d methods to async
functions, so `__await__` works inside the body and exceptions
propagate as rejected Promises that the literal `.__await__` keyword
re-throws as Ruby exceptions.

This is the same trick `Sinatra::Base.generate_method` uses for HTTP
route blocks — see `vendor/sinatra/base.rb:1813`.

### Explicit `.__await__` at every async boundary

Opal's `# await: true` is **token-driven**: only the literal
`.__await__` token is rewritten to JS `await`. Calling a helper that
does `__await__` internally returns a Promise that the caller still has
to await again. So:

- `dispatch_scheduled` ends each job with `invoke_scheduled_job(...).__await__`
- `invoke_scheduled_job` ends the bound-method call with `.__await__`
- `Cloudflare::Scheduled.dispatch_js` ends with `.dispatch_scheduled(...).__await__`
- `/test/scheduled/run` ends with `.dispatch_scheduled(...).__await__`
- Tests use `app.dispatch_scheduled(...).__await__`

The thenable JS check (`typeof p.then === 'function'`) is kept around the
`.__await__` so non-Promise returns (sync blocks in tests) are not
needlessly awaited.

### `await_promise` helper

`Cloudflare::Scheduled.await_promise(p) = p.__await__` exists as a
single-spot indirection that future code paths (e.g. the AI streaming
demo in Phase 10) can call without scattering `__await__` markers
through their own files. It is async itself, so its own callers still
have to `__await__` the helper's return — there is no escape from the
"every async boundary needs a literal `__await__`" rule. The docstring
calls this out so future maintainers don't fall back into the trap.

### Cron expression validation

We enforce 5- or 6-field whitespace structure at `schedule` time so a
typo throws `ArgumentError` at boot, not silently never-fires at
runtime. We don't attempt to parse the cron expression itself —
Cloudflare always passes back the literal string from `wrangler.toml`,
so exact-string match is the right policy and a parser would just be
dead weight.

A `match:` keyword lets test code override the matcher with
`match: ->(_c) { true }` for "always run" jobs without touching
wrangler.toml.

### Per-job error isolation

`dispatch_scheduled` wraps each job in its own `begin / rescue ::Exception`
so one bad job never kills its siblings. Each result Hash carries
`name`, `cron`, `ok`, `duration`, and (on failure) `error: "Class: msg"`.

### Local stdout invisibility (NOT a bug)

`puts` from inside a `scheduled`-context block doesn't reach
`wrangler dev` stdout the way it does from HTTP routes. We confirmed
this is purely a console.log capture quirk — D1 and KV writes from the
same block DO land. Diagnostics during development used HTTP route
inspection of the persisted state instead of `puts`.

## Out of scope (deferred)

- **Dynamic cron registration** — Workers requires static
  `wrangler.toml` declaration. Sinatra DSL therefore has no
  `unschedule` / `reschedule`.
- **Cron expression parsing** — exact-string match is what the
  runtime guarantees; no need.
- **Cross-job sequencing** — each job runs independently; no
  declarative "run B after A" yet. Use `wait_until` to keep work
  alive past the dispatcher's return when needed.

## Bench

| Phase | bundle (uncompressed) |
|---|---|
| Phase 8 (a5b1b20) | 5.6 MB |
| **Phase 9 (this branch)** | 5.6 MB (+ ~6 KB for scheduled dispatcher + Sinatra extension) |

Negligible bundle delta — Cron Triggers add Ruby code only, no new
vendored gems.

## Phase 8 → Phase 9 carryover

- Re-uses Phase 7 `# await: true` + `__await__` async pattern verbatim
  for D1 / KV bindings.
- Re-uses Phase 8's "register helper, gate by env var" production
  safety pattern (`HOMURABI_ENABLE_SCHEDULED_DEMOS`).
- Re-uses Phase 7's `bin/init-local-d1` SQLite bootstrap pattern;
  schema simply adds a `heartbeats` table.

## Next-phase enablers

Phase 11 candidates that this work unlocks:
- **Queues binding** — `schedule`-style DSL would mirror `consume` for
  Queue triggers; ScheduledContext is already the right shape for that.
- **Durable Objects** — `wait_until` / `ctx` plumbing carries straight
  through.
- **Workers AI streaming (Phase 10.3)** — `Cloudflare::Scheduled.await_promise`
  + the worker.mjs `ctx.waitUntil` pattern is the exact bridge needed
  for SSE streams.
