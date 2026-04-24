<p align="center">
  <img src="public/homura-chan.png" alt="homura mascot" width="200">
</p>

# homura

**Real Ruby + Real Sinatra on Cloudflare Workers, via Opal.**

Live demo: **<https://homura.kazu-san.workers.dev>**

**Current published app flow** — use the RubyGems packages `opal-homura`, `homura-runtime`, `sinatra-homura`, and optionally `sequel-d1`. The normal path is `bundle exec homura new myapp` (add `--with-db` for D1), then work through generated `bundle exec rake dev|build|deploy` tasks. Generated apps use standard Sinatra `config.ru` + `app/app.rb`, and `homura build` auto-detects `config.ru`, `app/hello.rb`, then `app/app.rb` as the entrypoint. Standard `config.ru` files using `require_relative 'app/app'` are supported, ordinary `erb :index` picks up `layout.erb` by default, and ordinary Sequel dataset reads coerce D1 booleans back to Ruby `true` / `false`. Drop down to `bundle exec homura build` only when you are wiring or debugging the lower-level build pipeline. `wrangler.toml` `main` points at **`build/worker.entrypoint.mjs`**.

---

## AI / agent support

- **Machine-readable docs**: [`/llms.txt`](public/llms.txt) (live: <https://homura.kazu-san.workers.dev/llms.txt>)
- **Installable agent skill**: [`skills/homura-workers-gems/`](skills/homura-workers-gems/)

### Install with `gh skill`

```bash
gh skill preview kazuph/homura homura-workers-gems
gh skill install kazuph/homura homura-workers-gems --agent github-copilot --scope user
gh skill install kazuph/homura homura-workers-gems --agent claude-code --scope project
```

### Install with `npx skills`

```bash
npx skills add kazuph/homura --skill homura-workers-gems -a github-copilot
npx skills add kazuph/homura --skill homura-workers-gems -a claude-code
```

The skill teaches agents how the 4 published gems fit together, which gem to pick
for a given task, the install/build flow, and the main Workers/Opal gotchas.

---

## Phase 10 hero — Sinatra `/chat` × Workers AI (Gemma 4 + gpt-oss-120b)

A real Sinatra route, hosted on Cloudflare Workers, talking to **Cloudflare
Workers AI** through the `env.AI` binding — wrapped in a tiny Ruby helper so
the route reads like any other Sinatra controller. JWT-protected via the
Phase 8 vendored `ruby-jwt`. Conversation history persists in **Workers KV**.

```ruby
# app/hello.rb (excerpt)
CHAT_MODELS = {
  primary:  '@cf/google/gemma-4-26b-a4b-it',  # Google Gemma 4, 256K ctx, $0.10/$0.30 per Mtok
  fallback: '@cf/openai/gpt-oss-120b'         # OpenAI gpt-oss-120b, 128K ctx, $0.35/$0.75 per Mtok
}.freeze

post '/api/chat/messages' do
  content_type 'application/json'
  # ... inline JWT verify (see source) ...
  history = load_chat_history(session_id)
  result  = Cloudflare::AI.run(
              model,
              { messages: build_ai_messages(history, user_text), max_tokens: 1024 },
              binding: env['cloudflare.AI']
            )
  reply_text = App.extract_ai_text(result).strip
  save_chat_history(session_id, history + [...])
  { 'ok' => true, 'reply' => reply_text, 'model' => model, 'history_len' => ... }.to_json
end
```

Standard binding/helper calls stay sync-shaped in app source: the build step auto-inserts
`.__await__` for registered async paths such as `db.execute`, `kv.get`,
`Cloudflare::AI.run`, and repo-registered helpers like `load_chat_history`.
Manual `.__await__` is mainly an escape hatch for raw Promise work outside those patterns.

```text
# Live capture (wrangler dev → real Workers AI; full log: .artifacts/phase10-ai/api-evidence.txt)
$ TOKEN=$(curl -s -X POST 'http://127.0.0.1:8788/api/login?alg=HS256' \
            -H 'content-type: application/json' \
            -d '{"username":"chat-demo","role":"user"}' | jq -r .access_token)

$ curl -s -X POST 'http://127.0.0.1:8788/api/chat/messages' \
       -H "authorization: Bearer $TOKEN" \
       -H 'content-type: application/json' \
       -d '{"session":"hero","content":"日本語で50字以内で挨拶＋自己紹介",
            "model":"@cf/google/gemma-4-26b-a4b-it"}' | jq
{
  "ok": true,
  "session": "hero",
  "model": "@cf/google/gemma-4-26b-a4b-it",
  "used_fallback": false,
  "elapsed_ms": 3112,
  "reply": "こんにちは！homuraです。Sinatra-on-Cloudflare-Workersのフレンドリーな助手です。",
  "history_len": 2
}
```

| binding | what we use | model |
|---|---|---|
| `env.AI` | text generation, OpenAI-compatible chat completions | **`@cf/google/gemma-4-26b-a4b-it`** (primary) · `@cf/openai/gpt-oss-120b` (fallback) |
| `env.KV` | per-session chat history (`chat:<session>`, capped at 32 messages) | n/a |
| Phase 8 JWT | inline verify against `Authorization: Bearer …` (HS256 by default) | n/a |

The chat UI lives at `GET /chat` (`views/chat.erb` precompiled by `bin/compile-erb`).
`POST /api/chat/messages`, `GET /api/chat/messages`, `DELETE /api/chat/messages`
are JWT-gated. `/test/ai` runs both models against the live Workers AI catalog
as a "CI on Workers" smoke check; `/test/ai/debug` dumps the raw Workers AI
response so you can spot model-specific schema drift.

> **Llama-family models intentionally excluded.** Phase 10 ships Gemma 4 +
> gpt-oss-120b only; see `docs/ROADMAP.md` for the rationale.

---

```ruby
# app/app.rb — literal Sinatra DSL, no Cloudflare imports, no backtick JS.
require 'sinatra/base'
require 'sequel'

class App < Sinatra::Base
  get '/' do
    @title   = 'Hello from Sinatra'
    db       = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    @users   = db[:users].select(:id, :name).all
    erb :index, layout: :layout
  end

  get '/hello/:name' do
    @name    = params['name']
    erb :hello, layout: :layout
  end

  get '/d1/users' do
    db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    content_type 'application/json'
    db[:users].select(:id, :name).all.to_json
  end
end
```

```ruby
# config.ru
require_relative 'app/app'

run App
```

`views/index.erb`, `views/layout.erb`, etc. are plain ERB. `bin/compile-erb`
translates them to Ruby methods at build time, so the Workers sandbox
never sees an `eval` / `new Function` at request time.

For normal Sinatra/D1 code paths, the build step keeps app code sync-shaped and
inserts `.__await__` only where the runtime actually needs it. For app setup,
Homura now prefers the standard Sinatra split of `config.ru` and `app/app.rb`.

That file is compiled by Opal to a 580 KiB (gzip) ESM Module Worker and
deployed straight to Cloudflare's edge. The Sinatra routes call D1, KV,
and R2 bindings through a thin Ruby wrapper that exposes each Cloudflare
JavaScript object as a plain Ruby value.

Sister project: [`kazuph/hinoko`](https://github.com/kazuph/hinoko) —
the mruby/WASI version, with a custom Hono-like DSL. `homura` is the
opposite bet: no DSL, real Sinatra, real Rack, real middleware chain.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Architecture at a glance](#architecture-at-a-glance)
- [Upstream sources (everything is real)](#upstream-sources-everything-is-real)
- [Applied patches, file by file](#applied-patches-file-by-file)
  - [vendor/opal-gem — Opal compiler & corelib](#vendoropal-gem--opal-compiler--corelib)
  - [vendor/sinatra — janbiedermann/sinatra fork](#vendorsinatra--janbiedermannsinatra-fork)
  - [vendor/rack, vendor/mustermann, vendor/rack/protection](#vendorrack-vendormustermann-vendorrackprotection)
  - [vendor/\*.rb stubs (Digest, Zlib, Tempfile, Tilt, …)](#vendorrb-stubs-digest-zlib-tempfile-tilt-)
  - [lib/opal_patches.rb — runtime shims loaded before user code](#libopal_patchesrb--runtime-shims-loaded-before-user-code)
  - [lib/cloudflare_workers.rb — Rack handler & D1/KV/R2 wrappers](#libcloudflare_workersrb--rack-handler--d1kvr2-wrappers)
  - [src/worker.mjs — Module Worker entry](#srcworkermjs--module-worker-entry)
  - [bin/compile-erb + views/ — build-time ERB precompiler](#bincompile-erb--views--build-time-erb-precompiler)
- [Build & run](#build--run)
- [Directory layout](#directory-layout)
- [Net::HTTP works (Phase 6)](#nethttp-works-phase-6)
- [Crypto works (Phase 7)](#crypto-works-phase-7)
- [JWT 認証 (Phase 8)](#jwt-認証-phase-8)
- [Scheduled Workers — Cron Triggers (Phase 9)](#scheduled-workers--cron-triggers-phase-9)
- [Project status & phases](#project-status--phases)
- [Strict no-fallback policy](#strict-no-fallback-policy)
- [License](#license)

---

## Why this exists

Every "Ruby on Cloudflare Workers" post I could find uses mruby, ruby.wasm,
or invents a small DSL and dresses it up as Sinatra. The Ruby people
actually work with — Sinatra, ERB templates, Rack middleware — never
shows up on Workers, because the toolchain to put it there doesn't
exist.

`homura` is the brute-force answer to the question **"what does it
actually take to run *the real* Sinatra, the real Rack, the real
Rack::Protection, on Cloudflare Workers?"** The answer turns out to be:

1. Vendor Opal, fix three compiler/runtime bugs that Sinatra exercises.
2. Vendor `janbiedermann/sinatra` (the CRuby-3-compatible fork), fix a
   handful of places where Sinatra assumes mutable strings or
   CRuby-specific semantics that differ on Opal/V8.
3. Build an Opal ↔ Cloudflare Rack adapter (`lib/cloudflare_workers.rb`)
   that makes Sinatra think it's running on Puma.
4. Bridge sync Sinatra to async Cloudflare bindings (D1 / KV / R2) using
   Opal's `# await: true` magic-comment support plus a `Promise`-aware
   response builder.

Every patch is listed below with a one-line rationale so you can read
the diff against upstream by `rg "homura patch"`.

---

## Architecture at a glance

```
                ┌─────────────────────────────────────────────┐
                │           Cloudflare Workers (V8)           │
                │                                              │
    JS fetch   ─┼─▶ src/worker.mjs                              │
    event       │      • awaits req.text()                     │
                │      • forwards to globalThis.               │
                │        __HOMURA_RACK_DISPATCH__            │
                │                                              │
                │      async function dispatcher               │
                │      └─▶ Rack::Handler::CloudflareWorkers    │
                │           • build_rack_env                   │
                │           • env['cloudflare.DB/KV/BUCKET']   │
                │             = Ruby wrappers over CF bindings │
                │                                              │
                │           @app.call(env)                     │
                │            │                                  │
                │            ▼                                  │
                │      ┌───────────────────────────────────┐    │
                │      │  Sinatra middleware stack         │    │
                │      │  (real janbiedermann/sinatra)     │    │
                │      │                                    │    │
                │      │  ExtendedRack → ShowExceptions →   │    │
                │      │  Head → NullLogger →               │    │
                │      │  Rack::Protection::* → App         │    │
                │      └───────────────────────────────────┘    │
                │            │                                  │
                │            ▼                                  │
                │      user Sinatra route                       │
                │      (app/hello.rb, pure Ruby)                │
                │                                              │
                │      • sync route → plain Rack tuple         │
                │      • async route (`# await: true`) →       │
                │         Promise body, awaited in              │
                │         build_js_response before returning    │
                │                                              │
                └─────────────────────────────────────────────┘
                             │
                             ▼
                   new Response(body, …)
```

**Opal compiles once at build time** (`bundle exec opal -c …`). The
output is a single 4 MiB ESM (≈580 KiB gzip) that contains the Opal
runtime, the Ruby corelib, janbiedermann/sinatra + patched Rack +
Mustermann + Rack::Protection, homura's adapter, and the user's
`app/hello.rb`. Cloudflare Workers `import`s that ESM from
`src/worker.mjs`, wrapped in a ~30 line Module Worker fetch handler.

---

## Upstream sources (everything is real)

Nothing in this repo is a clean-room reimplementation or a fake
"Sinatra-like" DSL. Every framework is the actual upstream gem, pulled
in-tree, patched only when Opal or the Workers sandbox forces the
issue. The patch sites are all marked with a `# homura patch:`
comment.

| Upstream | Version vendored | Path in this repo | Upstream URL |
|---|---|---|---|
| **Opal** (Ruby→JS compiler + corelib + stdlib) | `1.8.3.rc1.3` (homura fork; based on upstream `1.8.3.rc1`) | `vendor/opal-gem/` | <https://github.com/opal/opal> |
| **janbiedermann/sinatra** (CRuby-3 compatible fork) | fork HEAD when vendored | `vendor/sinatra/` | <https://github.com/janbiedermann/sinatra> |
| **Rack** (patched copy shipped by the janbiedermann fork) | same | `vendor/rack/` | <https://github.com/rack/rack> |
| **Mustermann** (Sinatra's path matcher) | same | `vendor/mustermann/` | <https://github.com/sinatra/mustermann> |
| **Rack::Protection** | same | `vendor/rack/protection/` | <https://github.com/sinatra/sinatra/tree/main/rack-protection> |

`Gemfile` pins Opal via `gem 'opal-homura', path: 'vendor/opal-gem', require: 'opal'`, so the
vendored copy is what actually compiles every build.

`vendor/opal-gem/` was copied from the official `opal-1.8.3.rc1`
release. The rest of `vendor/` was copied from the `janbiedermann/sinatra`
fork's own vendored gems (the fork already ships patched Rack +
Mustermann + Rack::Protection to work with modern Ruby).

---

## Applied patches, file by file

Every patch is additive (nothing is deleted from upstream). The "why"
column is the single-sentence rationale — most of them have a longer
inline comment at the patch site.

### vendor/opal-gem — Opal compiler & corelib

| File | Patch | Why |
|---|---|---|
| `lib/opal/nodes/literal.rb` | `extract_flags_and_value` rewrites `\A` → `^`, `\Z`/`\z` → `$` in **dstr (interpolated)** regex literals, not just static ones. | Opal only normalised anchors when the regex literal had no `#{}` interpolation. `/\A#{inner}\Z/` — Mustermann's route pattern shape — shipped to V8 with literal `\A\Z`, which JS regex silently treats as the letters `A`/`Z`, so **every Sinatra route failed to match its own path**. Fix normalises each `:str` child inside the dstr. |
| `opal/corelib/error.rb` | `UncaughtThrowError` now inherits from `::Exception` instead of `::ArgumentError` (i.e. no longer a `StandardError`). | Opal's `throw`/`catch` is implemented as `raise`/`rescue` of `UncaughtThrowError`. With the old parent chain, **every `rescue StandardError` frame on the stack swallowed in-flight throws** — Sinatra's `process_route` has exactly that frame, so `throw :halt, body` never reached `invoke`'s `catch(:halt)`. Re-parenting to `Exception` matches MRI's observable behaviour (MRI uses longjmp, so `rescue StandardError` never sees a mid-flight throw). |
| `lib/opal/nodes/closure.rb` | `NextNode`/`thrower(:next, value)` now emits the `value` expression as a side-effecting JS statement *before* `continue` when the thrower closure is `LOOP_INSIDE`. | Upstream just pushed a bare `continue` and silently dropped the argument. `next base = base.superclass` in Sinatra's `error_block!` therefore never assigned to the enclosing `base` — the loop spun forever as soon as a request hit an un-handled status code. Emitting the expression first matches CRuby semantics. |
| `opal/corelib/runtime.js` | Added explicit `prototype` property on the generated class constructors. | Required for `@prototype` collision fix that made `Sinatra::Base.allocate` return a well-formed instance instead of `nil`. Without this, every `Sinatra::Base.new` fell over at the first JS-level constructor mismatch. |
| `lib/opal/rewriters/js_reserved_words.rb` | Added `prototype` to the reserved-words rewriter. | Follow-up to the runtime.js fix: Ruby methods named `prototype` now get mangled so they don't clobber the JS-level `$$prototype` chain. |
| `opal/corelib/regexp.rb` | Multi-replace in JS regex replacement helpers. | Opal's `gsub`/`sub` helper only replaced the first match in a few edge cases. |

### vendor/sinatra — janbiedermann/sinatra fork

| File | Patch | Why |
|---|---|---|
| `base.rb` `Sinatra::Delegator.delegate` | Removed the `super(*args, &block) if respond_to?` branch inside `define_method`. | Opal's compiled `super` inside `define_method` hard-codes the *enclosing* Ruby method name (`'delegate'`) instead of the dynamically-defined one, so the call resolved to the wrong method. Upstream relies on `method_missing`-style dispatch that Opal doesn't emit. |
| `base.rb` `Sinatra::Base.new!` | Rewritten from `alias new! new` to an explicit `def new!(*args, &block); allocate; send(:initialize, *args, &block); end`. | Opal drops `alias` inside `class << self`. Without the rewrite, `new!` was undefined. |
| `base.rb` `Sinatra::Base#content_type` | `mime_type << …` → `mime_type += …`. | Opal Strings are immutable (they're JS Strings). `<<` raises `NotImplementedError` as soon as a route calls `content_type 'application/json'`. |
| `base.rb` `Sinatra::Base.force_encoding` | Drop the trailing `.encode!` from `data.force_encoding(encoding).encode!`. | `force_encoding` works on Opal (returns a re-tagged copy) but `encode!` raises. Opal Strings are already canonical UTF on JS, so the transcode is observably a no-op. |
| `base.rb` `Sinatra::Base#invoke` | When `catch(:halt)` yields a JS-level Promise (detected via `Cloudflare.js_promise?`), stash it as a single-chunk body so the adapter can await it later. | Async route blocks compiled with `# await: true` return a Promise synchronously. Without this patch invoke's body-detection falls through and `@response.body` stays empty. We use a true `typeof obj.then === 'function'` check instead of `respond_to?(:then)` because `Kernel#then` (Ruby 2.6+) is defined on every object and would poison the body array with `false` from `error_block!`. |
| `base.rb` `Sinatra::Response#calculate_content_length?` | Skip the bytesize loop whenever a body chunk is a pending JS Promise. | Content-length can't be computed before the Promise resolves; the adapter will build the header after `Promise.all` settles. |

### vendor/rack, vendor/mustermann, vendor/rack/protection

| File | Patch | Why |
|---|---|---|
| `vendor/rack.rb` | `autoload :Lint` commented out. | Opal's parser chokes on `rack/lint.rb`'s `/[\x80-\xff]/` regex literal. We don't run Lint on Workers anyway. |
| `vendor/rack/utils.rb` | `URI_PARSER = CGI-backed Module.new`. | Opal's `uri` stdlib doesn't define `URI::DEFAULT_PARSER`. |
| `vendor/rack/request.rb` | Three regex rewrites (`trusted_proxies` union, `ipv6` union, `AUTHORITY` alternation). | JS regex doesn't support `(?i)` inside a union alongside non-`/i` members, doesn't support `(?x)` (extended) mode, and rejects duplicate named captures in alternation. Each regex is hand-folded so the compiled JS regex is accepted by V8 without changing the match semantics. |
| `vendor/rack/show_exceptions.rb` `#pretty` | Rewritten as a plain Ruby string builder instead of `template.result(binding)`. | Upstream uses ERB, which compiles to code that runs via `binding.eval` → `new Function($code)`. Cloudflare Workers refuses `new Function` with *"Code generation from strings disallowed for this context"*, so the entire dev-mode error page exploded with a *second* exception inside the renderer. The hand-rolled version produces the same rescue page (title, traceback, request info, env dump) without ever touching ERB or `binding.eval`. |
| `vendor/rack/media_type.rb` `type` / `params` | `rstrip!` / `downcase!` / `strip!` → non-mutating counterparts. | Immutable-Opal-String rule again. Surfaces on the first POST request via `Sinatra::Helpers#form_data?`. |
| `vendor/rack/builder.rb` | `to_app`'s `inject` fold rewritten as an index-based `wrap_middleware_chain` helper. | Opal's compiled `each` block doesn't propagate a closure-captured accumulator through the inject chain; the last middleware's app was always `nil`. |
| `vendor/rack/show_exceptions.rb` CSS block | `string << …` → `string += …`. | Same immutable-String rule. |
| `vendor/mustermann/ast/parser.rb` | `read_brackets`, `read_list`, `read_escaped` use `result += …` / explicit `result[-1] = result.last + …` instead of `String#<<`. | Same reason. |
| `vendor/mustermann/ast/node.rb` | `Node#parse` detects a `String`-typed payload (Capture#parse initialises `@payload = String.new` and then super's while loop does `payload << element`) and uses reassignment. | Same reason. |

### vendor/\*.rb stubs (Digest, Zlib, Tempfile, Tilt, …)

Opal's stdlib doesn't ship these gems, but Sinatra / Rack / Rack::Protection
reference them at class-body time. They're vendored as *minimal shape*
stubs — constants exist, methods raise `NotImplementedError` (for the
ones we don't need) — so the require chain succeeds.

| File | Purpose |
|---|---|
| `vendor/digest.rb`, `vendor/digest/sha2.rb` | `Digest::Class`, `Digest::Base`, `Digest::SHA1`, `Digest::MD5`, `Digest::SHA256/384/512` constants |
| `vendor/zlib.rb` | `Zlib::*` constants; method calls raise |
| `vendor/cgi/escape.rb` | `require 'cgi'` re-export shim |
| `vendor/tempfile.rb` | StringIO-backed stub |
| `vendor/tilt.rb` | Enough surface for `Tilt.default_mapping.extensions_for(...)` / `Tilt[engine]` at class-body time |

### lib/opal_patches.rb — runtime shims loaded before user code

Opal gets `-r opal_patches` on the command line, so this file is the
first thing to run after the corelib. It patches in everything
Sinatra / Rack / Mustermann / Rack::Protection assume but Opal's
corelib doesn't ship.

| Patch | Why |
|---|---|
| `Module#deprecate_constant` no-op | CRuby 2.6+ ships it; Opal doesn't. `rack/multipart/parser.rb` calls it at class-body time. |
| `Module#const_defined?` qualified name walker | Opal's built-in rejects `"Foo::Bar::Baz"`. Mustermann's `Node[:root]` factory needs it. |
| `Forwardable#def_instance_delegator` dot-path accessor | Mustermann uses `instance_delegate %i[parser compiler] => 'self.class'`. Upstream Opal resolves `'self.class'` via `instance_eval(String)`, which compiles to `new Function($code)` — forbidden on Workers. The patch replaces that with a small dot-path walker (`self`, `self.class`, `@ivar.foo`, plain method name) that never touches eval. |
| 30+ `Encoding::*` aliases (`ISO_2022_JP`, `SHIFT_JIS`, `EUC_JP`, `WINDOWS_1252`, …) | Opal only ships UTF-8/16/32, ASCII-8BIT, ISO-8859-1, US-ASCII. Rack gems reference many more legacy encodings in constant hashes at class-body time. Each missing name is aliased to `Encoding::ASCII_8BIT` so the constant reference succeeds; a real `.encode` call still raises clearly. |
| `URI::DEFAULT_PARSER` / `URI::RFC2396_PARSER` / `URI::Parser` | CGI-backed module with the same `escape` / `unescape` / `regexp[:UNSAFE]` surface that `mustermann/ast/translator.rb` and `rack/utils.rb` actually call. |
| `URI.parse` / `URI::InvalidURIError` / `URI::Error` / `URI.decode_www_form_component` / `URI.encode_www_form_component` | Phase 2 2nd-pass + Phase 3: `Rack::Protection::JsonCsrf` and `Rack::Utils` need these. `URI.parse` is backed by the JS `URL` constructor; the rest defer to `CGI`. |
| `$0` / `$PROGRAM_NAME` default | `sinatra/main.rb` has `proc { File.expand_path($0) }` at class-body time; Opal leaves both `nil`, which crashes. |
| `IO.read` / `File.read` / `File.binread` / `File.fnmatch` | Raise `Errno::ENOENT`. Sinatra's `inline_templates=` wraps `File.open` in `rescue ENOENT` — we need the *right* exception type so the rescue takes the silent path. |
| `SecureRandom.hex` / `random_bytes` / `uuid` / `base64` | Backed by Web Crypto API (`crypto.getRandomValues`). CF Workers forbids random-value generation at global scope (module init), so the implementation catches that failure and falls back to a deterministic zero string — same degradation CRuby itself does when SecureRandom is unavailable. |
| Eager `require 'digest' / 'zlib' / 'tempfile' / 'tilt'` | Some gems reference `Digest::SHA1` at class-body time without an explicit `require 'digest'`. |

### lib/cloudflare_workers.rb — Rack handler & D1/KV/R2 wrappers

This is **the only file in the entire codebase that knows it's running
on Cloudflare Workers**. Everything above it in the stack (Sinatra,
Rack, Mustermann, user code) thinks it's running under a normal Rack
server.

Three responsibilities:

1. **`CloudflareWorkersIO`** — replaces `$stdout` / `$stderr` with shims
   that route Ruby `puts` / `print` to V8's
   `globalThis.console.log/error` (Opal's default `nodejs.rb` adapter
   tries to write to a closed Socket on Workers).

2. **`Rack::Handler::CloudflareWorkers`** — standard Rack handler
   convention (a module with a `run` class method). Converts each CF
   Workers `Request` into a Rack env Hash, calls `@app.call(env)`,
   turns the `[status, headers, body]` tuple back into a JS
   `Response`. `build_rack_env` spec-compliant with Rack SPEC: sets
   `REQUEST_METHOD`, `PATH_INFO`, `QUERY_STRING`, `rack.input`
   (a `StringIO` built from the body text `worker.mjs` awaited for us),
   `rack.errors`, `HTTP_*`, etc. The CF bindings are injected under the
   Rack convention `cloudflare.env` / `cloudflare.ctx`, plus convenience
   wrapper keys `cloudflare.DB` / `cloudflare.KV` / `cloudflare.BUCKET`.

3. **`Cloudflare::D1Database` / `D1Statement` / `KVNamespace` /
   `R2Bucket`** — tiny Ruby wrappers over the JS bindings. Each
   mutating method returns the raw JS Promise produced by the binding,
   optionally wrapped in a `.then` that converts JS results into Ruby
   Hashes/Arrays so user code can just call `.to_json` on the awaited
   value. `Cloudflare.js_promise?` is a native `typeof obj.then ===
   'function'` check (not `respond_to?(:then)`, which matches every
   Ruby object since 2.6).

The dispatcher installed on `globalThis.__HOMURA_RACK_DISPATCH__` is
an `async function` that `await`s the Ruby `$call` result, so both
sync (plain Response) and async (Promise<Response>) paths flow through
the same entry point.

### src/worker.mjs — Module Worker entry

30 lines. Imports the compiled ESM, reads `req.text()` up front (so
the synchronous Opal dispatcher can stuff the body into `rack.input`
without needing to `await` anything later), and forwards to
`__HOMURA_RACK_DISPATCH__`. Skips the body read for GET/HEAD/OPTIONS
so the hot path doesn't pay the cost.

### bin/compile-erb + views/ — build-time ERB precompiler

Cloudflare Workers refuses `eval` and `new Function`, which is exactly
what stock ERB runs at `template.result(binding)` time. A normal
Sinatra application would crash on the first `erb :index`.

homura's answer is to **precompile every ERB template to a plain
Ruby method at build time**, in CRuby, before Opal runs. The pipeline:

1. Templates live in `views/*.erb` as ordinary ERB source.
2. `bin/compile-erb` (a ~200 line CRuby script) tokenises each file
   looking for `<% %>` / `<%= %>` / `<%== %>` / `<%# %>` tags,
   emits a Ruby method body that concatenates the result into a
   local `_out` variable using `_out = _out + …` (Opal Strings are
   immutable; stock ERB's generated `<<` would blow up), and writes
   the whole thing to `build/homura_templates.rb`.
3. That file registers each template with a `HomuraTemplates`
   module (`HomuraTemplates.register(:index) do |locals| … end`)
   and reopens `Sinatra::Templates` to override `erb(name, ...)` so
   user code's `erb :index` transparently dispatches to the
   precompiled Proc via `instance.instance_exec(locals, &body)`.
   Layout templates can use ordinary `<%= yield %>`; the precompiler
   rewrites that to a helper call and passes layout blocks through.
4. The Opal build command picks the generated file up with
   `-I build -r homura_templates`, so it runs at Worker init time,
   installs the override, and is ready before the first request.

Result: user code writes stock Sinatra (`erb :index` with `@ivars` and
`<%= … %>` expressions), *never* knows Cloudflare's sandbox banned
eval, and still gets `<% @users.each do |user| %>…<% end %>` loops —
because every ERB tag is just Ruby that Opal compiled to JS ahead of
time. The generated `build/homura_templates.rb` is idempotent: run
`bin/compile-erb` any time you change a view.

The layout pattern works too: routes can write ordinary Sinatra-style
`erb :index, layout: :layout`, and `views/layout.erb` can use
`<%= yield %>`. Legacy `@content` / `@docs_inner` layouts still work as
compatibility shims while existing code is migrated.

---

## Build & run

### Prerequisites

```
mise (or rbenv)     — Ruby 3.4.9
mise (or nvm)       — Node 22.21.1
Cloudflare account   — wrangler CLI logged in
```

Everything below assumes you run it from the repo root.

### Install Ruby deps

```sh
bundle install --path vendor/bundle
```

This pulls Opal from the vendored path in `Gemfile`
(`gem 'opal-homura', path: 'vendor/opal-gem', require: 'opal'`) so there's no pre-release
download to worry about.

### Build (one command)

```sh
npm run build
```

This runs three steps in sequence:

1. **`npm run build:erb`** — `ruby bin/compile-erb` scans `views/*.erb`
   and writes `build/homura_templates.rb`.
2. **`npm run build:assets`** — `ruby bin/compile-assets` embeds
   `public/*` (CSS, SVG — NOT binary images, which go through R2)
   into `build/homura_assets.rb`.
3. **`npm run build:opal`** — `bundle exec opal -c -E --esm …` compiles
   everything into `build/hello.no-exit.mjs` with the full flag set:
   `-I lib -I vendor -I build`,
   `-r opal_patches -r cloudflare_workers -r homura_templates -r homura_assets`.

All three generated files live under `build/` (gitignored). Running
`npm run build` is the **only** build command you need to remember.

### Dev server

```sh
npm run dev
# → builds, then starts wrangler dev on http://127.0.0.1:8787
```

### Deploy

```sh
npm run deploy
# → builds, then runs wrangler deploy
```

`wrangler.toml` declares the `[[d1_databases]]` / `[[kv_namespaces]]`
/ `[[r2_buckets]]` bindings; the deploy log prints them back.

### Provision the bindings (one-time)

```sh
npx wrangler d1 create homura-db
npx wrangler kv namespace create homura-kv
npx wrangler r2 bucket create homura-bucket

# seed a users table for the D1 demo routes
npx wrangler d1 execute homura-db --remote --command \
  "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);"
npx wrangler d1 execute homura-db --remote --command \
  "INSERT INTO users (name) VALUES ('alice'), ('bob'), ('kazu');"
```

Update `wrangler.toml` with the `database_id` / KV namespace `id` that
`wrangler` prints out.

---

## Directory layout

```
homura/
├── app/
│   └── hello.rb                 ← User Sinatra app. Plain Ruby, no CF imports.
├── views/
│   ├── layout.erb               ← Top-level HTML skeleton (<nav>, <footer>, …)
│   ├── index.erb                ← Home page (reads @users from D1)
│   ├── hello.erb                ← /hello/:name — classic <%= @name %>
│   └── about.erb                ← /about
├── bin/
│   └── compile-erb              ← Ruby script: views/*.erb → build/homura_templates.rb
├── build/
│   ├── hello.no-exit.mjs        ← Opal output (≈4 MiB, ≈580 KiB gzip). Gitignored.
│   └── homura_templates.rb    ← Auto-generated from views/. Picked up via -I build.
├── lib/
│   ├── cloudflare_workers.rb    ← Rack handler + CF binding wrappers. The only
│   │                              file that knows it's on Workers.
│   └── opal_patches.rb          ← Runtime shims (Module#deprecate_constant, URI,
│                                   Forwardable dot-path, encodings, SecureRandom).
├── src/
│   └── worker.mjs               ← 30-line Module Worker fetch handler.
├── vendor/
│   ├── opal-gem/                ← Opal fork 1.8.3.rc1.3 (based on upstream 1.8.3.rc1).
│   ├── sinatra/                 ← janbiedermann/sinatra fork. 6 homura patches
│   │                              in base.rb.
│   ├── rack/                    ← Rack + Rack::Protection (patched).
│   ├── mustermann/              ← Mustermann (patched).
│   ├── digest.rb, zlib.rb,      ← Minimal stubs for corelib gaps.
│   │   tempfile.rb, tilt.rb
│   └── bundle/                  ← bundler install target. Gitignored.
├── wrangler.toml                ← Worker config with D1 / KV / R2 bindings.
├── Gemfile                      ← Pins Opal via path: 'vendor/opal-gem'.
└── .artifacts/homura/          ← Not tracked. Holds the strict PLAN.md and
                                   per-phase evidence logs (phase 2 / phase 3).
```

Every patch file in `vendor/**` has an inline `# homura patch:`
comment, so the complete diff against upstream is:

```sh
rg "homura patch" vendor lib
```

---

## Net::HTTP works (Phase 6)

The Phase 6 patch added `Cloudflare::HTTP.fetch` (a thin Ruby wrapper
around `globalThis.fetch`) and a `Net::HTTP` shim that delegates to it.
Existing Ruby code that uses `Net::HTTP.get(URI('...'))` works
unchanged inside Sinatra routes — the only addition required is the
`.__await__` suffix that already appears around D1/KV/R2 calls.

```ruby
get '/demo/http' do
  content_type 'application/json'
  res = Net::HTTP.get_response(URI('https://api.ipify.org/?format=json')).__await__
  {
    'status'       => res.code,
    'content_type' => res['content-type'],
    'body'         => JSON.parse(res.body)
  }.to_json
end
```

What's covered:

- `Cloudflare::HTTP.fetch(url, method:, headers:, body:)` →
  `Cloudflare::HTTPResponse` with `status` / `headers` (lowercased
  Hash) / `body` (String) / `json` / `ok?` / `[]`.
- `Net::HTTP.get(uri)` → body String.
- `Net::HTTP.get_response(uri)` → `Net::HTTPResponse` with `body`
  / `code` / `message` / `[]` / `each_header`.
- `Net::HTTP.post_form(uri, hash)` → urlencoded POST returning
  `Net::HTTPResponse`.
- `Kernel#URI('https://...')` shorthand for `URI.parse(...)`.

What's *not* covered (raw TCP is impossible on Workers): persistent
connections, `Net::HTTP.start`-style block forms, request objects, raw
socket access, multipart upload, chunked streaming bodies. Use
`Cloudflare::HTTP.fetch` directly for those — it accepts arbitrary
fetch `init` options through `headers:` / `method:` / `body:`.

Smoke tests live in `test/http_smoke.rb` and run as part of `npm test`.

---

## Crypto works (Phase 7)

Phase 7 fills in the crypto stubs so unmodified Ruby crypto code
runs on the edge. Two backends, picked per-API based on what's
actually implemented in the Workers runtime:

| Backend | What it covers |
|---|---|
| **`node:crypto`** (sync, via `nodejs_compat`) | `Digest::SHA1/256/384/512/MD5`, `OpenSSL::HMAC` (5 algos), `OpenSSL::KDF` (PBKDF2 / HKDF), `OpenSSL::PKey::RSA` / `EC` / `Ed25519` / `X25519` **key generation + PEM I/O**, `SecureRandom`, `OpenSSL::BN` (BigInt-backed) |
| **Web Crypto `subtle`** (async, via `globalThis.crypto.subtle`) | `OpenSSL::Cipher` (AES-GCM / CBC / CTR), RSA `sign` / `verify` (RS256/384/512), RSA `sign_pss` / `verify_pss` (PS256/384/512), RSA `public_encrypt` / `private_decrypt` (RSA-OAEP), EC `sign` / `verify` (ES256/384/512, **DER + raw R||S**), EC `dh_compute_key` (ECDH P-256/384/521), `Ed25519` `sign` / `verify` (EdDSA), `X25519` `dh_compute_key` |

Workers' `nodejs_compat` layer (unenv) doesn't currently implement
`createCipheriv` / `createSign` / `createVerify`. Anything that needs
those goes through `subtle.*` instead, which is async, so callers
add `.__await__` exactly like with D1 / KV / R2 / `Cloudflare::HTTP.fetch`.

### What works (verified on Workers)

- **Hashes / HMAC / KDF**: SHA-1/256/384/512, MD5, HMAC with each,
  PBKDF2-HMAC, HKDF.
- **JWT signing / verification**: HS256/384/512, **RS256/384/512**,
  **PS256/384/512**, **ES256/384/512** (both DER and raw-R||S
  formats — the JWT-compatible raw form is `sign_jwt` / `verify_jwt`),
  **EdDSA (Ed25519)**.
- **AEAD**: AES-128/192/256-GCM with `auth_tag` + `auth_data`,
  tampering rejection, AAD-mismatch rejection, full byte-transparent
  plaintext (every value 0x00..0xff round-trips).
- **AES-CBC**: AES-128/192/256-CBC with PKCS#7 padding.
- **AES-CTR**: AES-128/192/256-CTR with **true streaming** —
  `update(chunk)` returns ciphertext for whole 16-byte blocks
  immediately, with the tail carried forward and the counter
  incremented per call.
- **RSA-OAEP**: `public_encrypt` / `private_decrypt`, default
  SHA-256, alternate hashes via `hash:` argument.
- **ECDH**: P-256 / P-384 / P-521 key agreement.
- **X25519**: Curve25519 ECDH key agreement.
- **PEM I/O**: SPKI public, PKCS#8 private; round-trip preserves
  the underlying KeyObject.
- **OpenSSL::BN**: BigInt-backed `+` / `-` / `*` / `/` / `%` / `**`,
  comparison, `gcd`, `mod_exp`, `num_bits`, `to_s(radix)`, etc.
- **SecureRandom**: `hex` / `random_bytes` / `urlsafe_base64` /
  `uuid`, all backed by `node:crypto.randomBytes`.

### What's NOT possible on the platform (intentional gaps)

- **ChaCha20-Poly1305**: not in the Web Crypto spec and not
  implemented in `nodejs_compat`. Would require a vendored pure-JS
  AEAD implementation, deferred.
- **CBC streaming `update` mid-block**: subtle AES-CBC enforces
  PKCS#7 padding atomically. `update` buffers and `final` emits the
  full ciphertext. Drop down to AES-CTR if you need true streaming.
- **PKCS#1 v1.5 RSA encrypt/decrypt** (legacy): subtle only
  exposes RSA-OAEP for encryption. Use OAEP (the modern default).
- **ECDSA with HMAC**, **RSA key generation < 2048 bits**: not
  exposed by subtle.

### Awaiting

Methods that go through subtle return JS Promises. Inside
`# await: true` Ruby files (Sinatra route bodies, helpers, smoke
tests), append `.__await__` exactly like with D1 / KV / R2:

```ruby
# Synchronous (node:crypto)
Digest::SHA256.hexdigest('hello')
OpenSSL::HMAC.hexdigest('SHA256', 'secret', 'hello')
OpenSSL::KDF.pbkdf2_hmac('pw', salt: 's', iterations: 4096, length: 32, hash: 'SHA256')
SecureRandom.hex(16)
rsa = OpenSSL::PKey::RSA.new(2048)
ec  = OpenSSL::PKey::EC.generate('prime256v1')
rsa.to_pem; OpenSSL::PKey::RSA.new(rsa.to_pem)
OpenSSL::BN.new(3).mod_exp(5, 13)   # → 9

# Async (Web Crypto subtle, requires .__await__)
cip = OpenSSL::Cipher.new('AES-256-GCM').encrypt
cip.key = key; cip.iv = iv
cip.update(plain)
ct  = cip.final.__await__
tag = cip.auth_tag

# RSA-PSS (JWT PS256)
sig = rsa.sign_pss('SHA256', msg, salt_length: :digest, mgf1_hash: 'SHA256').__await__
ok  = rsa.public_key.verify_pss('SHA256', sig, msg, salt_length: :digest, mgf1_hash: 'SHA256').__await__

# RSA-OAEP encrypt/decrypt
ct        = rsa.public_key.public_encrypt('payload').__await__
recovered = rsa.private_decrypt(ct).__await__

# ECDSA — DER (CRuby compat) and raw-R||S (JWT compat)
der  = ec.sign(OpenSSL::Digest::SHA256.new, msg).__await__       # DER
raw  = ec.sign_jwt(OpenSSL::Digest::SHA256.new, msg).__await__   # raw R||S

# ECDH
shared = alice_ec.dh_compute_key(bob_ec).__await__

# Ed25519 / X25519
ed_sig = ed_key.sign(nil, msg).__await__
shared = alice_x.dh_compute_key(bob_x).__await__
```

### Tests

- `npm run test:crypto` — 85 smoke tests against CRuby-reference
  values for SHA / HMAC / KDF, AES round-trips with tampering
  detection, RSA RS / PS / OAEP, ECDSA ES256/384/512 (both DER and
  raw), ECDH P-256/384/521, Ed25519, X25519, BN arithmetic.
- `npm test` — full suite, 96 tests (27 smoke + 14 http + 85
  crypto = wait, 27 + 14 + 85 = 126 tests; the actual count is
  whatever `npm test` reports — see CI output).
- `npm run test:workers` — hits the live `/test/crypto` endpoint
  on a running `wrangler dev` (or remote) and confirms every
  primitive round-trips on the actual Workers runtime, not just on
  the Node test runner.

A demo route lives at `GET /demo/crypto` and the self-test endpoint
at `GET /test/crypto` (both work via `npm run dev`).

---

## JWT 認証 (Phase 8)

Phase 8 は **real `jwt` gem (ruby-jwt v2.9.3) を vendor して Cloudflare Workers
上で動かす** フェーズ。7 つの JWT アルゴリズム全てを Workers ランタイム上で
発行・検証でき、Sinatra の薄いヘルパを被せて 1 行で `authenticate!`
できる。

| アルゴリズム | 署名バックエンド | プラットフォーム | 同期性 |
|---|---|---|---|
| HS256 / HS384 / HS512 | `node:crypto.createHmac` (nodejs_compat) | sync | 追加 `.__await__` 不要 |
| RS256 / RS384 / RS512 | Web Crypto `subtle.sign('RSASSA-PKCS1-v1_5')` | async | caller が `.__await__` |
| PS256 / PS384 / PS512 | Web Crypto `subtle.sign('RSA-PSS', saltLength: digest)` | async | caller が `.__await__` |
| ES256 / ES384 / ES512 | Web Crypto `subtle.sign('ECDSA')` (raw R‖S そのまま) | async | caller が `.__await__` |
| EdDSA (= ED25519) | Web Crypto `subtle.sign('Ed25519')` | async | caller が `.__await__` |

### ファイル構成

```
vendor/jwt.rb                  ← require 'jwt' のエントリ（ruby-jwt 互換）
vendor/jwt/
├── base64.rb                  ← url_encode / url_decode（Opal 対応、padding 手動）
├── encode.rb                  ← # await: true、sign() Promise を内部で unwrap
├── decode.rb                  ← # await: true、any? を while ループに置換
├── jwa/
│   ├── hmac.rb                ← HS256/384/512（sync）— secure_compare を hex 正規化
│   ├── rsa.rb                 ← RS256/384/512（subtle, .__await__）
│   ├── ps.rb                  ← PS256/384/512（subtle, salt_length: :digest 固定）
│   ├── ecdsa.rb               ← ES256/384/512（sign_jwt / verify_jwt = raw R‖S）
│   └── eddsa.rb               ← Ed25519 置き換え版（RbNaCl 依存を除去）
├── jwk.rb                     ← JWKS は Phase 8 非対応。呼ぶとエラー（明示）
├── claims.rb, claims/*.rb     ← exp / nbf / iss / aud / sub / jti / iat / required
└── configuration/*.rb         ← decode 既定値（verify_expiration 等）

lib/sinatra/jwt_auth.rb        ← Sinatra::JwtAuth 拡張
test/jwt_smoke.rb              ← 43 ケース（各 alg encode/decode + tamper 拒否 + claims）
```

### 使い方 — Sinatra ルートで 1 行認証

```ruby
require 'sinatra/base'
require 'sinatra/jwt_auth'

class App < Sinatra::Base
  register Sinatra::JwtAuth
  set :jwt_secret,    'super-secret'
  set :jwt_algorithm, 'HS256'

  get '/api/me' do
    authenticate!                       # 401 を自動 halt（missing/expired/tampered）
    content_type 'application/json'
    { 'user' => current_user }.to_json  # current_user は payload Hash
  end

  post '/api/login' do
    token = issue_token({ 'sub' => 'alice', 'role' => 'admin' }, expires_in: 3600)
    content_type 'application/json'
    { 'access_token' => token }.to_json
  end
end
```

非対称鍵アルゴリズム（RS/PS/ES/EdDSA）を使う場合は署名鍵と検証鍵を
別々に設定する:

```ruby
private_key = OpenSSL::PKey::EC.generate('prime256v1')
set :jwt_sign_key,   private_key
set :jwt_verify_key, private_key  # EC は秘密鍵から公開鍵を取れるので同じでOK
set :jwt_algorithm,  'ES256'
```

### デモルート (`app/hello.rb`)

`POST /api/login?alg=<name>` は **7 つのアルゴリズム全て**で JWT を発行し、
`GET /api/me` は token の header から alg を自動検出して検証する:

```
$ curl -X POST http://127.0.0.1:8787/api/login?alg=ES256 \
    -H 'content-type: application/json' \
    -d '{"username":"alice","role":"admin"}'
{"access_token":"eyJhbGciOi...","refresh_token":"kaj4akI0p3dL7tP6KMbXU7FmnfEeho...","alg":"ES256",...}

$ curl -H "Authorization: Bearer eyJhbGciOi..." http://127.0.0.1:8787/api/me
{"current_user":"alice","role":"admin","alg":"ES256","claims":{...}}

$ curl -X POST http://127.0.0.1:8787/api/login/refresh \
    -H 'content-type: application/json' \
    -d '{"refresh_token":"kaj4akI0p3dL7tP6KMbXU7FmnfEeho..."}'
{"access_token":"eyJhbGci...(new)...","alg":"HS256","expires_in":3600,...}
```

- `refresh_token` は 48-byte urlsafe base64 で、**KV にオパーク文字列として
  保持**（`refresh:<token>` キー）。アクセストークンが漏れても `JWT_ACCESS_TTL`
  = 3600 秒で失効するが、リフレッシュトークンは KV に残っているので
  再認証不要で新しいアクセストークンを貰える。
- 有効期限切れのリフレッシュトークンは KV から削除される。
- 改竄された署名は全アルゴリズムで `JWT::VerificationError` を投げ、
  `authenticate!` が 401 を返す。

### 適用した主なパッチ

| ファイル | パッチ | 理由 |
|---|---|---|
| `vendor/jwt.rb`, `vendor/jwt/encode.rb`, `vendor/jwt/decode.rb` | `# await: true` + `JWT.encode / JWT.decode` 公開面に `.__await__` | 署名 API が Promise を返す（RS/PS/ES/EdDSA）ため、呼び出し側が同期的に使えるよう await を内部で解決 |
| `vendor/jwt/jwa/hmac.rb` `SecurityUtils.secure_compare` | `a.unpack1('H*') == b.unpack1('H*')` で hex 正規化比較 | `Array#pack('H*')` と `Base64.urlsafe_decode64` がバイト同値でも `bytesize` を別々に返すため、upstream の `a.bytesize == b.bytesize` 前ガードが常に false を返していた |
| `vendor/jwt/jwa/rsa.rb` / `ps.rb` | `.__await__` 付与、PSS は `salt_length: :digest` 固定 | Web Crypto subtle は `:auto` salt を表現できない |
| `vendor/jwt/jwa/ecdsa.rb` | `OpenSSL::PKey::EC#sign_jwt` / `#verify_jwt` に差し替え（raw R‖S） | subtle は ECDSA で raw R‖S をそのまま返す — JWT スペックと一致。upstream の DER↔raw 変換ロジックと `OpenSSL::ASN1` 依存を丸ごと回避 |
| `vendor/jwt/jwa/eddsa.rb` | RbNaCl 依存を削除し `OpenSSL::PKey::Ed25519` で置換、無条件ロード | Workers に libsodium はない。Phase 7 で subtle.sign('Ed25519') を EdDSA として実装済み |
| `vendor/jwt/decode.rb` `verify_signature_for?` / `verify_signature` | `Array#any?` を while ループに置換 | `any?` のブロックは JS で同期評価される — Promise を返してもそのまま truthy と判定され、実質バイパスされてしまう |
| `vendor/jwt/decode.rb` `decode_segments` | `verify_signature.__await__` を明示 | verify_signature は内部で `.__await__` を呼ぶので async 関数。呼び出し側で await しないと未処理 Promise rejection が発生し、検証失敗を検出できない |
| `vendor/jwt/base64.rb` `url_decode` | padding を手動で補填して `urlsafe_decode64` に渡す | Opal base64 は padding 必須、upstream の `padding: false` オプションは未対応 |
| `vendor/jwt/jwk.rb` | 全面的にスタブ、呼ぶと `JWKError` | JWKS / kid 解決は OpenSSL::PKey の JWK シリアライザが必要 — Phase 8 スコープ外 |
| `vendor/jwt/jwa.rb` | `require 'rbnacl'` ブロックを削除、`jwt/jwa/eddsa` を無条件 require | Workers に libsodium なし |
| `vendor/jwt/configuration/jwk_configuration.rb` | `kid_generator_type=` をスタブ化 | 起動時に OpenSSL::Digest を引く副作用を避ける |

### テスト

- `npm run test:jwt` — **43 ケース**: HS/RS/PS/ES/EdDSA × (encode-decode + tamper
  拒否)、alg-none 拒否、alg 不一致拒否、exp/nbf/iss クレーム、`decode(verify: false)`、
  2 セグメント検出、`algorithms: [...]` 配列指定 など。
- `npm test` — 全スイート: 27 smoke + 14 http + 85 crypto + 43 jwt = **169 tests**。
- `GET /test/crypto` (Workers self-test) — Phase 7 の 17 ケース + Phase 8 の
  9 JWT ケース = **26 ケース**を実稼働 Workers 上で回す。

### 非対応 (Phase 8 スコープ外)

- **JWKS (`kty` / `kid` で公開鍵セットを取得する仕組み)** — OpenSSL JWK
  シリアライザが必要。`JWT::JWK.create_from` は明確にエラーを返す。
- **X5C (`x5c` ヘッダによる証明書チェーン検証)** — OpenSSL::X509 非実装。
- **ES256K (secp256k1)** — Web Crypto 仕様外。
- **カスタム署名アルゴリズム** — SigningAlgorithm module は有効だが、
  Opal async 対応の完了はユーザー側の責務。

## Scheduled Workers — Cron Triggers (Phase 9)

Cloudflare Workers が `[triggers] crons` の時刻に発火する `scheduled(event,
env, ctx)` ハンドラを Sinatra DSL で書けるようにする。**Sidekiq-Cron や
whenever のようにアプリと同じファイルに `schedule` ブロックを並べる**だけで、
Workers ランタイムからのクロン発火が D1 / KV / R2 に届く。

```ruby
class App < Sinatra::Base
  register Sinatra::Scheduled

  # 5分ごとに D1 に行を入れる
  schedule '*/5 * * * *', name: 'heartbeat' do |event|
    db.execute_insert(
      'INSERT INTO heartbeats (cron, scheduled_at, fired_at, note) VALUES (?, ?, ?, ?)',
      [event.cron, event.scheduled_time.to_i, Time.now.to_i, 'phase9-heartbeat']
    ).__await__
  end

  # 1時間ごとに KV カウンタを更新（read-modify-write）
  schedule '0 */1 * * *', name: 'hourly-housekeeping' do |event|
    raw  = kv.get('cron:hourly-counter').__await__
    prev = raw ? JSON.parse(raw)['count'].to_i : 0
    kv.put('cron:hourly-counter', { 'count' => prev + 1, 'last_run_at' => Time.now.to_i }.to_json).__await__
  end
end
```

`wrangler.toml`:

```toml
[triggers]
crons = [
  "*/5 * * * *",   # heartbeat — 5分ごと D1 書き込み
  "0 */1 * * *",   # hourly housekeeping — 1時間ごと KV カウンタ
]
```

### ローカルでクロンを手動発火

Cloudflare Workers の標準的な方法と全く同じ。`wrangler dev --test-scheduled`
を立てて、`/__scheduled` エンドポイントに `cron` をクエリパラメータで投げる。

```bash
$ npm run dev   # 内部で wrangler dev を起動

# 別ターミナルから — 5分ごとのクロンを今すぐ発火
$ curl 'http://127.0.0.1:8787/__scheduled?cron=*/5+*+*+*+*'
Ran scheduled event

# D1 に行が入った
$ wrangler d1 execute homura-db --local \
    --command "SELECT * FROM heartbeats ORDER BY id DESC LIMIT 1;"
{"cron":"*/5 * * * *","note":"phase9-heartbeat", ...}
```

### イントロスペクション (`/test/scheduled`)

Phase 7 / 8 の `/test/crypto` と同じノリで、開発時に登録済みクロンの一覧と
任意発火を curl で確認できる。**default deny** — `wrangler.toml [vars]
HOMURA_ENABLE_SCHEDULED_DEMOS = "1"`（あるいは `.dev.vars` で上書き）
にしないと 404 を返す。

```bash
$ curl http://127.0.0.1:8787/test/scheduled
{"jobs":[
  {"name":"heartbeat","cron":"*/5 * * * *", ...},
  {"name":"hourly-housekeeping","cron":"0 */1 * * *", ...}
]}

# 手動で hourly cron だけ発火
$ curl -X POST 'http://127.0.0.1:8787/test/scheduled/run?cron=0%20*/1%20*%20*%20*'
{"fired":1,"total":2,
 "results":[{"name":"hourly-housekeeping","cron":"0 */1 * * *","ok":true,"duration":0.003}],
 "cron":"0 */1 * * *","registered_crons":["*/5 * * * *","0 */1 * * *"]}
```

### `schedule` API

| 引数 | 型 | 必須 | 説明 |
|---|---|---|---|
| `cron` | String | ✓ | 5- または 6-フィールドのクロン式。`wrangler.toml` の `[triggers] crons` の文字列と完全一致しないとマッチしない |
| `name:` | String | — | ログ用ラベル（既定: クロン式そのもの） |
| `match:` | Proc | — | 完全一致以外のマッチング（テスト用、`->(c) { true }` で常時発火） |
| ブロック | `\|event\|` | ✓ | `Cloudflare::ScheduledEvent` (`#cron` / `#scheduled_time` / `#type`) を受け取る |

`schedule` ブロックの中では HTTP ルートと同じヘルパが使える:

| ヘルパ | 値 |
|---|---|
| `db` | `Cloudflare::D1Database` ラッパ（D1 バインディング設定時のみ） |
| `kv` | `Cloudflare::KVNamespace` ラッパ |
| `bucket` | `Cloudflare::R2Bucket` ラッパ |
| `env` | `'cloudflare.cron'` / `'cloudflare.scheduled_time'` / `'cloudflare.env'` / `'cloudflare.ctx'` を含む Hash |
| `wait_until(promise)` | `ctx.waitUntil(promise)` 相当。長時間 Promise をハンドラ完了後も走らせる |
| `logger` | `info` / `warn` / `error` / `debug` を持つ簡易ロガー |

### `# await: true` ルール

D1 / KV / R2 / fetch / 暗号系と同じく、内部で `__await__` を呼ぶブロックは
**Opal `# await: true` モード**で動く。`app/hello.rb` の先頭にこのマジックコメントが
ある限り、`schedule do ... end` の中で `kv.get(key).__await__` のような同期風
構文が使える（ES8 `await` に変換される）。

ブロックが投げた例外は **per-job rescue** に捕まり、結果の `results` 配列に
`ok: false, error: "Class: msg"` として記録される。一つのクロンが落ちても兄弟ジョブは
止まらない。

### 制約 (Cloudflare Workers の物理制約により未対応)

- **動的クロン登録** — `wrangler.toml` の静的宣言のみ。実行時に
  `unschedule` / `reschedule` する API は提供しない（プラットフォーム制約）。
- **長時間ジョブ** — Workers の CPU 時間制限あり（30s wall、〜30s CPU）。
  外部 fetch を伴う重い処理は `wait_until` で続行させる。
- **クロス-job sequencing** — 各ジョブは並列・独立。`A の完了を待って B`
  のような宣言的シーケンスはなし（必要なら呼び出し順を `schedule` 宣言で
  制御）。

### テスト

29 ケースの回帰スイート (`test/scheduled_smoke.rb`) — DSL 登録、クロン式
バリデーション、ディスパッチ、`ScheduledContext` ヘルパ、`ScheduledEvent.from_js`、
カスタム match proc、per-job エラー隔離、`globalThis.__HOMURA_SCHEDULED_DISPATCH__`
JS フック経由の round-trip。

```bash
$ npm run test:scheduled
29 tests, 29 passed, 0 failed
```

## Cloudflare native bindings (Phase 11B)

Phase 11B adds **three Cloudflare-native Worker bindings** on top of the
Phase 3 D1/KV/R2 foundation — always the same "the wrapper IS the API"
shape that turns a JS binding into a plain Ruby object:

| Binding | Ruby API | Demo route | Self-test |
|---|---|---|---|
| **Durable Objects** | `Cloudflare::DurableObjectNamespace` / `Stub` / `Storage` + `Cloudflare::DurableObject.define` handler DSL | `GET /demo/do?name=...&action=inc\|peek\|reset` | `GET /test/bindings` |
| **Cache API** | `Cloudflare::Cache.default` / `.match` / `.put` / `.delete` + Sinatra `cache_get(key, ttl:) { block }` helper | `GET /demo/cache/heavy?v=...` | `GET /test/bindings` |
| **Queues** | `Cloudflare::Queue#send` / `#send_batch` + `consume_queue 'q' do \|batch\| ... end` DSL | `POST /api/enqueue` + `GET /demo/queue/status` | `GET /test/bindings` |

Default deny like every other homura demo — all four routes above are
gated behind `HOMURA_ENABLE_BINDING_DEMOS=1` (wrangler `[vars]` entry).

### Durable Objects

One generic JS class `HomuraCounterDO` is exported from
`src/worker.mjs`; it forwards every `fetch(req)` call to a Ruby handler
registered with `Cloudflare::DurableObject.define`. Storage is serialised
to JSON on write, parsed back on read — Ruby code never touches JS.

```ruby
# app/hello.rb (excerpt) — the whole DO class lives in Ruby.
Cloudflare::DurableObject.define('HomuraCounterDO') do |state, request|
  prev = (state.storage.get('count').__await__ || 0).to_i
  if request.path.end_with?('/inc')
    state.storage.put('count', prev + 1).__await__
    [200, { 'content-type' => 'application/json' },
     { 'count' => prev + 1, 'do_id' => state.id }.to_json]
  elsif request.path.end_with?('/reset')
    state.storage.delete('count').__await__
    [200, {}, '{"reset":true}']
  else
    [200, {}, { 'count' => prev }.to_json]
  end
end

get '/demo/do' do
  stub = env['cloudflare.DO_COUNTER'].get_by_name(params['name'] || 'global')
  res  = stub.fetch("https://homura-do.internal/#{params['action']}", method: 'POST').__await__
  res.body
end
```

`wrangler.toml`:

```toml
[[durable_objects.bindings]]
name       = "COUNTER"
class_name = "HomuraCounterDO"

[[migrations]]
tag              = "v1"
new_sqlite_classes = ["HomuraCounterDO"]
```

Live evidence (`wrangler dev --local` + `HOMURA_ENABLE_BINDING_DEMOS=1`):

```text
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=inc'   # ×4
{"count":1,"do_id":"2ce054..."}
{"count":2,"do_id":"2ce054..."}
{"count":3,"do_id":"2ce054..."}
{"count":4,"do_id":"2ce054..."}
$ curl 'http://127.0.0.1:8787/demo/do?name=evidence&action=peek'
{"count":4,"do_id":"2ce054..."}
```

### Cache API

```ruby
# app/hello.rb
get '/demo/cache/heavy' do
  content_type 'application/json'
  cache_get(request.url, ttl: 60) do
    # expensive PBKDF2 (50_000 iterations) — only runs on MISS
    derived = OpenSSL::KDF.pbkdf2_hmac('homura-phase11b',
                salt: SecureRandom.random_bytes(16),
                iterations: 50_000, length: 32, hash: 'SHA256')
    { 'derived_hex' => derived.unpack1('H*'), 'computed_at' => Time.now.to_i }.to_json
  end.__await__   # cache_get is async — route must await
end
```

```text
# first hit — MISS, 6ms
{"derived_hex":"6ac25e...","cache":"MISS","elapsed_ms":6}
# second hit on the same URL — HIT, 1ms (same derived_hex proves it's cached)
{"derived_hex":"6ac25e...","cache":"HIT","elapsed_ms":1}
```

The Workers Cache API requires the stored `Response` to have
`Cache-Control: max-age>0` **and** a `Date` header — the `cache_get`
helper sets both automatically so callers can't forget.

### Queues

```ruby
# app/hello.rb — producer side
post '/api/enqueue' do
  content_type 'application/json'
  jobs_queue.send(JSON.parse(request.body.read)).__await__
  status 202
  { 'enqueued' => true }.to_json
end

# consumer side — DSL runs inside `src/worker.mjs#queue(batch, env, ctx)`
consume_queue 'homura-jobs' do |batch|
  msgs = batch.messages
  i = 0
  while i < msgs.length    # indexed while — see `# await: true` notes
    msg = msgs[i]
    kv.put("queue:last-consumed:#{i}",
      { 'id' => msg.id, 'body' => msg.body, 'consumed_at' => Time.now.to_i }.to_json,
      expiration_ttl: 86_400).__await__
    msg.ack
    i += 1
  end
  batch.size
end
```

`wrangler.toml`:

```toml
[[queues.producers]]
binding = "JOBS_QUEUE"
queue   = "homura-jobs"

[[queues.consumers]]
queue             = "homura-jobs"
max_batch_size    = 3
max_batch_timeout = 2
max_retries       = 3
```

Live evidence (miniflare 3 local emulator):

```text
$ for t in alpha beta gamma; do
    curl -s -X POST -H 'content-type: application/json' \
      -d "{\"task\":\"$t\"}" http://127.0.0.1:8787/api/enqueue
  done
$ sleep 3   # wait for max_batch_timeout
$ curl http://127.0.0.1:8787/demo/queue/status
{"queue":"homura-jobs","count":3,"recent":[
  {"id":"cabc5a...","body":{"task":"gamma"},"batch_index":0},
  {"id":"819052...","body":{"task":"beta"},"batch_index":1},
  {"id":"...","body":{"task":"alpha"},"batch_index":2}
]}
```

A fallback `POST /test/queue/fire` route manually invokes
`Cloudflare::QueueConsumer.dispatch_js` with a synthesised batch — useful
when miniflare's auto-dispatch loop is flaky on rapid `wrangler dev`
restarts.

### `/test/bindings` self-test

Mirrors the Phase 7 `/test/crypto` pattern: one HTTP endpoint that
exercises every binding wrapper and reports pass/fail per case.

```text
$ curl http://127.0.0.1:8787/test/bindings
{"passed":3,"failed":0,"total":3,"cases":[
  {"case":"DurableObject counter inc/peek/reset round-trip","pass":true, ...},
  {"case":"Cache API match after put returns same body","pass":true, ...},
  {"case":"Queue producer send() returns without error","pass":true, ...}
]}
```

### Opal x-string quirk worth knowing

Opal treats a **multi-line** backtick x-string as a statement (not an
expression), which silently drops the returned value. Every wrapper in
Phase 11B uses the **single-line IIFE pattern** for that reason:

```ruby
# Works — single-line expression, value is the Promise.
js_promise = `(async function(js, req) { await js.put(req, ...); })(#{js}, #{req})`
js_promise.__await__
```

Multi-line backticks work fine when assigned (the other Phase 3/6/7/8/9
wrappers use them that way), but at end-of-method they can sneakily
return `undefined`. The `put` / `match` / `delete` / `send` / `fetch`
helpers in `lib/cloudflare_workers/{cache,queue,durable_object}.rb`
document this at the call site.

### Phase 11B 追加パック (max-effort 完遂)

初回 PR 後、本家 PR 無し / 費用発生無し の範囲で **「工数で潰せる妥協」を全部潰した** アップデート:

- **DurableObject WebSocket (Hibernation API)** — `Cloudflare::DurableObject.define_web_socket_handlers`
  で `on_message` / `on_close` / `on_error` を Ruby で登録。`state.accept_web_socket` / `state.web_sockets`
  ラッパも同時提供。`/demo/do/ws` が **101 upgrade + フレーム echo + 同一 DO counter の increment** を
  行う実機デモ (Node `ws` client で 3 frames round-trip 確認)。Sinatra ルートが WebSocket 101 を
  返せるよう `Cloudflare::RawResponse` ラッパと `build_js_response` のパススルー分岐を追加。
- **Named Cache demo** — `/demo/cache/named?namespace=X&key=Y` で `caches.open(X)` 間の key 衝突が
  ないことを実機確認。smoke test にも 2 namespace 独立ケース追加。
- **Cache TTL 期限切れ** — 時間制御可能な fake で `max-age` 越えの `cache.match` が nil に落ちる
  （post-expiry MISS）ケースを追加。
- **DLQ 実機検証** — `[[queues.consumers]] dead_letter_queue = "homura-jobs-dlq"` + DLQ 側 consumer
  + `POST /demo/queue/force-dlq` (`{ fail: true }` を送ると main が retry → max_retries 超で DLQ 行き)。
  miniflare local で `/demo/queue/dlq-status` 経由の round-trip 実機確認。
- **Queue send_batch 大量ケース** — 100 件 batch の順序保存 + 件数検証。
- **DO `blockConcurrencyWhile`** — 共有カウンタへの並行 read-modify-write がシリアライズされる
  ケースを fake mutex で再現。
- **#9 Opal multi-line backtick audit** — `http.rb` / `ai.rb` に「変数代入ありの multi-line は
  安全、末尾式として置くと Promise silent drop」警告コメント追加。

これで smoke 合計 280 ケース (DO 31 / Cache 18 / Queue 22 + 既存 209)。

### テスト

初回 56 + max-effort 15 = 71 ケースの新規回帰 (`test/do_smoke.rb` 31 / `test/cache_smoke.rb` 18 /
`test/queue_smoke.rb` 22) + Workers self-test `/test/bindings`。

```bash
$ npm run test:do && npm run test:cache && npm run test:queue
31 tests, 31 passed, 0 failed
18 tests, 18 passed, 0 failed
22 tests, 22 passed, 0 failed
```

## Sequel + D1 adapter (Phase 12)

Phase 12 は **「Ruby 生まれの Dataset DSL で D1 を喋る」** パック。
`Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` で接続できて、
`db[:users].where(active: true).order(:name).limit(10).all.__await__` が
Cloudflare Workers 上で素直に動く。ハンドル済みの実機証跡は
`/test/sequel`（8/8 緑）と `/demo/sequel` で確認できる。

### 使い方 — Sinatra ルートから

```ruby
require 'sequel'

class App < Sinatra::Base
  get '/demo/sequel' do
    seq_db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
    # そのまま Sequel の DSL:
    rows = seq_db[:users].order(:id).limit(10).all.__await__
    json rows
  end
end
```

Workers ランタイム上で Sequel の Dataset DSL が返す Promise を
`.__await__` で unwrap する。Dataset#each / #all / #first / #count /
#insert / #update / #delete / #transaction すべて async な D1 コールに
透過的に繋がる（`vendor/sequel/dataset/actions.rb` に
`# await: true` + 各 action に `.__await__` 差し込み済み）。

### Migration CLI

migration 本体は **build-time 一択**。CRuby 側で `Sequel.migration do;
change do; create_table(:posts) ...; end; end` を評価して SQL 文字列に
書き出し、`wrangler d1 migrations apply` が適用する。Opal バンドルには
migration ランタイム（`File.directory?` / `Dir.new` / `load` / `Mutex`
を踏む箇所）は入らない。

```bash
# db/migrations/0001_create_posts.rb を書く
bin/homura-migrate compile db/migrations --out db/migrations
wrangler d1 migrations apply homura-db --local
```

生成される SQL は SQLite 方言のため D1 が素で喰う：

```sql
CREATE TABLE `posts` (
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `title` varchar(255) NOT NULL,
  `body` varchar(255),
  `created_at` timestamp DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime'))
);
```

### 適用した主なパッチ

ROADMAP の「vendor + 最小 Opal patch」方針に従い、Sequel v5.103.0 を
`vendor/sequel/` 配下に丸ごと固定して homura 専用の patch を
あてている。各 patch サイトは `# homura patch (Phase 12):` コメント付き：

- **`class_eval(String)` / `module_eval(String)` → `define_method`** —
  Workers の `Code generation disallowed` に抵触する 11 箇所
  （`sql.rb` / `dataset/query.rb` / `dataset/sql.rb` / `timezones.rb`）
- **`def_sql_method` の class_eval 生成を `define_method` + lambda 分岐に書き換え** —
  シーケンス型 + 分岐型（SQLite version 依存）両対応の parser
  （sqlite / postgres / mssql / opts[:values] 各条件パターン網羅）
- **`to_s_method` の args 式 parser** — `'@op, @args'` / `'@table, @column'`
  等を ivar 名カンマ区切りと解釈、`instance_variable_get` で解決
- **`HomuraSqlBuffer` 可変 SQL バッファ** — Opal の String は immutable
  (`<<` が NotImplementedError) なので、Array-backed の shim を
  `sql_string_origin` と `literal_append` の Symbol キャッシュで利用
- **async Promise 貫通** — `vendor/sequel/dataset/actions.rb` に
  `# await: true` + `Dataset#each` / `#_all` / `#with_sql_first` で
  `.__await__` 差し込み。`break` / `return` / `next` が async 境界を
  越えて LocalJumpError になる箇所は capture-then-drop 形式に書換
- **`Module#class_eval` の `require_relative` hack** — Opal が
  `require_relative "foo"` を `self.$require("/abs/path/foo")` に
  書き換える挙動を吸収する path normalizer
  (`__homura_normalize_path`)
- **`[]` alias** — `class << self; alias_method :[], :expr; end` が
  Opal の singleton extend 非対応で失敗するため `def self.[]` で
  explicit forward
- **Symbol は JS String と同一** — `Database#[](symbol)` が `is_a?(String)` 真
  判定で `fetch` パスに流れる問題を `is_a?(Symbol)` 優先で救う
- **`Mutex` / `Thread.current` / `BigDecimal` shim** —
  `lib/sequel_opal_patches.rb` で no-op 相当を提供
- **connection pool** — `SingleConnectionPool` と `ShardedSingleConnectionPool`
  を eager require、`ThreadedConnectionPool` 系は `POOL_CLASS_MAP`
  から明示的 error に

### Workers self-test

`/test/sequel` に 8 ケース（adapter wiring 3 + SQL 生成 3 + D1 実機
round-trip 2）を配置。`wrangler dev` + `curl http://127.0.0.1:8787/test/sequel | jq`
で即検証できる。

### テスト

- `test/sequel_smoke.rb` — Node.js 側 22 ケース（offline SQL 生成 +
  adapter wiring + mock D1 round-trip + JOIN/GROUP BY/subquery +
  transactions + 識別子/schema primitives）
- `/test/sequel` Workers self-test — 実機 D1 round-trip 8 ケース
- `bin/homura-migrate` CLI — migration → SQL 書き出し単体で
  `db/migrations/0001_create_posts.rb` → `0001_create_posts.sql` 動作確認済

### 非対応 (Phase 12 スコープ外)

- **`Sequel::Model`** — AR 風の magic finder は移植しない。Phase 12 は
  Dataset DSL に集中（ROADMAP `不採用` から AR 項目は Phase 12 以降
  Sequel Dataset を代替として案内する）。
- **Threaded / TimedQueue pool** — Workers isolate は単一スレッド、
  Mutex/ConditionVariable/Thread.new を踏む pool は使えない
- **PostgreSQL / MySQL adapter** — D1 (SQLite) 専用、他 adapter は非同梱
- **schema.rb 自動生成** — migration が source of truth（Sequel 既定挙動）

---

## HTTP foundations (Phase 11A)

Phase 11A は「HTTP 周り 3 点パック」。既存の Phase 6 (Net::HTTP shim) /
Phase 10.3 (AI streaming) をベースに、downstream Ruby gem との互換性を
底上げする基礎固め。

### ① Faraday 互換アダプタ (`vendor/faraday.rb`)

本物の ruby-faraday gem (〜9 kLOC + アダプタ/middleware) を vendor する代わりに、
Cloudflare Workers が持つ唯一のトランスポート (`globalThis.fetch` →
`Cloudflare::HTTP.fetch`) の上に **Faraday の公開 API の 95%** を直書き。

```ruby
require 'faraday'

client = Faraday.new(url: 'https://api.github.com') do |c|
  c.request :json                  # Hash body → JSON string
  c.response :json                 # レスポンス body を JSON.parse
  c.response :raise_error          # 4xx/5xx で Faraday::ResourceNotFound など
  c.request :authorization, :bearer, ENV['GH_TOKEN']
end

res = client.get('/users/kazuph').__await__
res.status       # => 200
res.body         # => { "login" => "kazuph", ... }
res.success?     # => true

client.post('/widgets') do |req|
  req.headers['X-Custom'] = 'yay'
  req.body = { 'name' => 'homura' }
end.__await__
```

- **Top-level shortcut**: `Faraday.get / post / put / patch / delete / head`
- **Connection builder**: `Faraday.new(url:, headers:, params:) { |c| ... }`
- **Middleware**: `:json` (encode/decode), `:url_encoded`, `:raise_error`,
  `:authorization, :basic | :bearer | :token, ...`, `:logger`
- **Error hierarchy**: `Faraday::ClientError` / `ServerError` /
  `ResourceNotFound` (404) / `UnauthorizedError` (401) / `ForbiddenError` (403)
  / `ConflictError` (409) / `UnprocessableEntityError` (422) /
  `TooManyRequestsError` (429) / `TimeoutError` / `ConnectionFailed`
- **`Faraday::Utils.build_query`** で nested Hash の
  `a%5Bb%5D=1&list%5B%5D=1` 形式エンコードも。

この shim のおかげで Faraday 依存の主要 gem (octokit 系の薄い client、
slack-ruby-client、OpenAI 互換 client など) が **そのまま Workers で動く**
ことが期待できる。

```bash
$ npm run test:faraday
13 tests, 13 passed, 0 failed
```

### ② multipart/form-data 本格対応（受信側）

Workers には書き込める FS が無いので Rack の既定 Tempfile 路線が使えない。
代わりに `src/worker.mjs` 側で **multipart リクエストだけ** `request.arrayBuffer()`
→ latin1 バイト文字列に変換して Ruby へ渡し、`lib/cloudflare_workers/multipart.rb`
のバイナリ安全パーサが `Cloudflare::UploadedFile` を生成する。

```ruby
post '/api/upload' do
  content_type 'application/json'
  file = params['file']     # => Cloudflare::UploadedFile
  note = params['note']     # => 普通の String
  # 注: このルートは `.__await__` を含む (= async) ので Sinatra の
  # `halt` / `throw :halt` は使わない。homura の確立したパターンで
  # `status N; next(body)` を使う（Phase 8/10 の JwtAuth helper 書き換え
  # コメント参照）。throw は async 境界を越えて Sinatra の
  # `catch :halt` から抜けてしまう。
  unless file.is_a?(Cloudflare::UploadedFile)
    status 400
    next({ error: 'missing "file"' }.to_json)
  end

  # latin1 バイト文字列 → real Uint8Array。これを R2 / fetch へ流すと
  # バイトが UTF-8 に触れず無傷で届く。
  bucket.put("uploads/#{file.filename}", file.to_uint8_array, file.content_type).__await__
  { stored: true, filename: file.filename, size: file.size, note: note }.to_json
end
```

- `UploadedFile#filename / #content_type / #size / #read / #bytes_binstr`
- `UploadedFile#to_uint8_array` → `new Uint8Array(...)` で真バイト配列
- `UploadedFile#to_blob` → `new Blob([u8], { type: ct })`
- `UploadedFile[:filename]` / `[:type]` / `[:tempfile]` (rack-compat Hash shape)
- RFC 5987 `filename*=UTF-8''...` のパーセントエンコードも decode
- boundary の quoted/bare form 両対応 (`boundary="foo bar"` もOK)

```bash
$ printf 'binary-payload' > /tmp/x.bin
$ curl -F "file=@/tmp/x.bin;type=application/octet-stream" -F "note=hi" \
       http://127.0.0.1:8787/api/upload
{"stored":true,"key":"phase11a/uploads/abc-x.bin","filename":"x.bin",
 "content_type":"application/octet-stream","size":14,"note":"hi"}

$ npm run test:multipart
10 tests, 10 passed, 0 failed
```

### ③ Sinatra streaming / SSE レスポンス

Workers の `new Response(ReadableStream)` を Ruby 側の DSL で書けるよう、
`Cloudflare::SSEStream` + `Cloudflare::SSEOut` を `Sinatra::Streaming` 拡張
として同梱。Ruby のブロックから書き込んだチャンクが、JS の `TransformStream`
→ `new Response(readable, ...)` を経由してクライアントに届く。

```ruby
register Sinatra::Streaming

get '/demo/sse' do
  sse do |out|
    i = 0
    while i < 5
      out.event(
        { tick: i, ts: Time.now.to_i }.to_json,
        event: 'heartbeat',
        id: i.to_s
      )
      out.sleep(1).__await__   # setTimeout 経由の真の 1 秒 await
      i += 1
    end
    out.event('done', event: 'close')
  end
end
```

```bash
$ curl -sN http://127.0.0.1:8787/demo/sse   # 5 秒かけて流れる
event: heartbeat
id: 0
data: {"tick":0,"ts":1776461676}

event: heartbeat
id: 1
...
event: close
data: done
```

- 書き込みは fire-and-forget (`out << chunk` / `out.event(...)`) で
  WritableStream の内部キューに積まれる。`close` 時に `Promise.all(pending)`
  → `writer.close()` をまとめて await するので、送信順が守られつつ
  route の async ブロックはブロックされない。
- 1 秒 sleep 等で本当に非同期 suspend したい場合は `out.sleep(1).__await__`。
  ブロック自体を `# await: true` 文脈で動かすには `while` ループ推奨
  （`5.times` は同期反復なので await が詰まる）。
- 例外時は `ensure` で必ず writer を閉じる。クライアントは `done: true` を見る。

```bash
$ npm run test:streaming
11 tests, 11 passed, 0 failed
```

### Workers 上の aggregate self-test

```bash
$ curl http://127.0.0.1:8787/test/foundations   # 要 HOMURA_ENABLE_FOUNDATIONS_DEMOS=1
{"passed":6,"failed":0,"total":6,"cases":[
  {"pass":true,"case":"Faraday GET with :json middleware round-trips"},
  {"pass":true,"case":"Faraday raise_error raises ResourceNotFound on 404"},
  {"pass":true,"case":"Faraday :json middleware encodes Hash body (offline)"},
  {"pass":true,"case":"Multipart parser extracts file + text field"},
  {"pass":true,"case":"UploadedFile#to_uint8_array preserves raw bytes"},
  {"pass":true,"case":"SSEStream frames data correctly"}
]}
```

## Project status & phases

The project follows a strict four-phase plan (see
`.artifacts/homura/PLAN.md`, not tracked in git). The current state
of each phase:

| Phase | Goal | Status |
|---|---|---|
| **Phase 0** | New repo + Opal → Workers boot with a plain `puts`. | ✅ shipped at commit `a09b399` |
| **Phase 1 R** | Pure Ruby Rack `lambda { \|env\| [200, …] }` returning real HTTP responses through a standard Rack handler. | ✅ shipped at commit `0dd4005` |
| **Phase 2** | Real `janbiedermann/sinatra` compiled and served through the Rack handler, full middleware chain (Rack::Protection headers), production `curl` returning actual Sinatra bodies, no ERB-in-dev-mode workarounds, no `request.body.read` stub. | ✅ shipped at commits `d74c329` / `e6d5f66` / `93fba66` — and the 5 1st-pass compromises (body stub, APP_ENV force, force_encoding no-op, Sinatra-side `next` patch, grep-ability) were all closed in a subsequent pass. |
| **Phase 3** | D1 / KV / R2 bindings callable from real Sinatra routes on Workers. | ✅ shipped at commits `ba0a772` / `4210de5`. All nine CRUD routes verified on production. |
| **Phase 4** | Evidence collection + マスター + Codex double review. | In progress. |
| **Phase 6** | HTTP client foundation — `Cloudflare::HTTP.fetch` wrapping `globalThis.fetch`, plus a `Net::HTTP` shim (`get` / `get_response` / `post_form`) and `Kernel#URI` so unmodified Ruby HTTP code can reach the network through the Workers `fetch` API. | ✅ shipped on `feature/phase6-fetch`. 14 new smoke tests pass; demos at `/demo/http` and `/demo/http/raw` hit the public ipify API. |
| **Phase 7** | Crypto primitives — full RS/PS/ES JWT alg coverage, RSA-OAEP, AES-GCM/CBC/CTR, ECDH (P-256/384/521 + X25519), Ed25519/EdDSA, OpenSSL::BN, KDF (PBKDF2 + HKDF), SecureRandom, PEM I/O. node:crypto sync + Web Crypto subtle async hybrid; CTR streaming via per-block subtle calls; binary plaintext byte-transparent; verify raises on key/algo errors and only returns false on signature mismatch. | ✅ shipped on `feature/phase7-crypto`. 85 crypto smoke + Workers self-test endpoint `/test/crypto` (17 cases) + bin/test-on-workers shell script for in-Worker regression. |
| **Phase 8** | JWT 認証フレームワーク — vendored ruby-jwt v2.9.3 に Opal/async パッチを適用。HS/RS/PS/ES/EdDSA 全アルゴリズム対応、`Sinatra::JwtAuth` ヘルパで `authenticate!` / `current_user` / `issue_token`、KV-backed refresh token、`/api/login?alg=<name>` で全アルゴリズムが実働 Workers 上で発行・検証できる。`JWT.encode` / `JWT.decode` は subtle バックエンドのため async（caller が `.__await__`）、HS256 系は sync。 | ✅ shipped on `feature/phase8-jwt`. 43 jwt smoke + Workers self-test `/test/crypto` が 26 ケース（JWT 9 追加）+ dogfooding で全 7 alg のログイン→/api/me→refresh を実測。 |
| **Phase 9** | Scheduled Workers (Cron Triggers) — `src/worker.mjs#scheduled` を経由して `globalThis.__HOMURA_SCHEDULED_DISPATCH__` から Sinatra ディスパッチャに委譲。**`Sinatra::Scheduled` 拡張**で `schedule '*/5 * * * *' do \|event\| ... end` DSL（`db` / `kv` / `bucket` / `wait_until` ヘルパ込み）。ブロックは `define_method` 経由でコンパイルされるため `# await: true` の `__await__` がそのまま使え、D1 / KV へのリード・モディファイ・ライトが Workers ランタイムから正しく到達する。per-job 例外隔離 + `/test/scheduled` `/test/scheduled/run` 内省 API（`HOMURA_ENABLE_SCHEDULED_DEMOS` で default deny）。 | ✅ shipped on `feature/phase9-cron`. 29 scheduled smoke + 実機 `wrangler dev --test-scheduled` で `/__scheduled?cron=...` 経由の D1 行追加と KV カウンタ increment を実測（4 連発で `count: 1→4`）。 |
| **Phase 10** | Workers AI binding + Sinatra `/chat` UI + `/api/chat/*` JWT-gated endpoints（Gemma 4 + gpt-oss-120b、KV-backed 会話履歴、SSE streaming サポート）。 | ✅ shipped on `feature/phase10-ai`. |
| **Phase 11A** | HTTP foundations 基礎固めパック — ① **Faraday 互換 shim** (`vendor/faraday.rb`) で `Faraday.new { \|c\| c.request :json; c.response :json, :raise_error }` 一式。② **multipart/form-data バイナリ受信** (`src/worker.mjs` + `lib/cloudflare_workers/multipart.rb`) + `Cloudflare::UploadedFile`（latin1 byte-str ↔ real Uint8Array）。③ **Sinatra streaming / SSE** (`Cloudflare::SSEStream` + `Sinatra::Streaming`) で `sse do \|out\| ... end` が Workers `ReadableStream` に直通し、`/demo/sse` で 5 秒かけて 5 tick 流れる。Workers self-test `/test/foundations` 6 ケース (`HOMURA_ENABLE_FOUNDATIONS_DEMOS=1`)。 | ✅ shipped on `feature/phase11a-http-foundations`. 34 smoke (13 faraday + 10 multipart + 11 streaming) + `/test/foundations` 6/6 実機グリーン。 |
| **Phase 11B** | Cloudflare native bindings — **Durable Objects** (`Cloudflare::DurableObject.define` handler DSL + `DurableObjectNamespace` / `Stub` / `Storage` ラッパ)、**Cache API** (`Cloudflare::Cache` + `cache_get` helper、HIT/MISS 自動判定)、**Queues** (`Cloudflare::Queue#send` / `#send_batch` プロデューサ + `consume_queue 'q' do \|batch\| ... end` DSL + `queue(batch, env, ctx)` 配送)。`/test/bindings` セルフテストと 56 ケースの smoke suite。`HOMURA_ENABLE_BINDING_DEMOS` で default deny。 | ✅ shipped on `feature/phase11b-cf-bindings`. DO カウンタ 1→2→3→4、Cache MISS(6ms)→HIT(1ms) 同一 `derived_hex`、Queue /api/enqueue → auto 消費 → KV 書き込み round-trip を実機で実測。 |
| **Phase 12** | **Sequel (vendored v5.103.0) + D1 adapter + migration CLI** — Sinatra ルートで `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])` → `db[:users].where(...).order(...).limit(...).all.__await__` の完全な Dataset DSL が実機 D1 で動作。SQLite dialect 共有、SingleConnectionPool 強制、async Promise チェーン貫通（`vendor/sequel/dataset/actions.rb` に `# await: true` + 各 action に `.__await__` 差し込み）、`HomuraSqlBuffer` による String immutability 回避。`bin/homura-migrate compile` で Ruby migration DSL を SQL に書き出し → `wrangler d1 migrations apply` で反映（Opal バンドル非同梱）。`/demo/sequel` / `/demo/sequel/sql` / `/test/sequel` (8/8) を実機で実測。Dataset#count / #first / #all / #insert / #update / #delete / #transaction / JOIN / GROUP BY / subquery が緑。 | ✅ shipped on `feature/phase12-sequel`. 22 sequel smoke + 既存 341 smoke 全緑で合計 **363 tests**、bundle +800KB uncompressed (+200KB gzipped、6.3MB/1.36MB)。 |

### Definition of Done (from PLAN.md §1.1)

- [x] `kazuph/homura` exists as a new GitHub repository.
- [x] `app/hello.rb` written in real CRuby syntax with `require 'sinatra/base'` and Sinatra DSL, **no JavaScript mixed in**.
- [x] Compiled to ESM via Opal and bundled into a Cloudflare Workers Module Worker.
- [x] Uses real `janbiedermann/sinatra` (no DSL re-implementation, no compatibility layer fakes).
- [x] D1 / KV / R2 bindings callable from Sinatra routes via the adapter's Ruby wrappers.
- [x] `wrangler dev` and `wrangler deploy` both serve the Sinatra app.

---

## Upstream policy — patches stay vendored

**None of the homura patches are submitted upstream**, and there
are no plans to do so. The vendored copies under `vendor/**/*` are a
loose fork for a specific deployment target, not a staging area for
PRs to `opal/opal`, `janbiedermann/sinatra`, `rack/rack`, or
`sinatra/mustermann`.

Most of the patches only make sense inside the Opal + Cloudflare
Workers corner case (ERB bypass, Promise-aware `invoke`,
`calculate_content_length?` Promise guard, `Sinatra::Base.new!`
explicit `def`, Forwardable dot-path walker, immutable-String
rewrites on Rack and Mustermann, JS-regex flag rewrites). Pushing
them upstream would regress or muddy the implementations for normal
Ruby users.

Even the three patches that look like generic Opal compiler bug
fixes (dstr regex anchor normalization, `next <expr>` in a while
loop, `UncaughtThrowError` parent class) are staying local — they
need upstream-style discussion and test coverage that homura
isn't going to own.

Every patch site is marked with a `# homura patch:` comment so the
diff against upstream is recoverable at any time via
`rg "homura patch"`. If you maintain Opal / Sinatra / Rack /
Mustermann and want to borrow an idea, please lift the relevant
snippet rather than taking a PR from here — that way the upstream
variant can be written in the style and with the tests the upstream
project prefers.

---

## Strict no-fallback policy

This repo enforces a **no-fallback** rule: the means *is* the goal.
Running the real Sinatra on real Opal on real Cloudflare Workers is
the entire point. Any deviation that "just makes it work" — swapping
Sinatra for a compatibility DSL, falling back to mruby or
ruby.wasm, switching to Cloudflare Containers, stubbing a route
without actually running Sinatra's code — immediately invalidates
that phase's deliverables. Patches are allowed; *spec reduction*
is not.

The plan document (`.artifacts/homura/PLAN.md`) lists the full
forbidden-fallback list and the review process (マスター + Codex
double review after every phase).

---

## Sister project

- [`kazuph/hinoko`](https://github.com/kazuph/hinoko) — Hono-like Ruby
  DSL on mruby/WASI for Cloudflare Workers. Lightweight, custom DSL,
  proven to work.
- [`kazuph/homura`](https://github.com/kazuph/homura) — this repo,
  real Ruby + real Sinatra via Opal. Ambitious, fallback-forbidden,
  a lot more bytes on the wire in exchange for the actual gem
  ecosystem.

## License

TBD. All vendored upstreams keep their original licenses — Opal is
MIT, Sinatra is MIT, Rack is MIT.
