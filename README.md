# homurabi

**Real Ruby + Real Sinatra on Cloudflare Workers, via Opal.**

Live demo: **<https://homurabi.kazu-san.workers.dev>**

```ruby
# app/hello.rb — literal Sinatra DSL, no Cloudflare imports, no backtick JS.
require 'sinatra/base'

class App < Sinatra::Base
  get '/' do
    @title   = 'Hello from Sinatra'
    @users   = env['cloudflare.DB'].prepare('SELECT id, name FROM users').all.__await__
    @content = erb :index      # ← real ERB, precompiled at build time
    erb :layout
  end

  get '/hello/:name' do
    @name    = params['name']
    @content = erb :hello
    erb :layout
  end

  get '/d1/users' do
    content_type 'application/json'
    env['cloudflare.DB'].prepare('SELECT id, name FROM users').all.__await__.to_json
  end
end

run App
```

`views/index.erb`, `views/layout.erb`, etc. are plain ERB. `bin/compile-erb`
translates them to Ruby methods at build time, so the Workers sandbox
never sees an `eval` / `new Function` at request time.

That file is compiled by Opal to a 580 KiB (gzip) ESM Module Worker and
deployed straight to Cloudflare's edge. The Sinatra routes call D1, KV,
and R2 bindings through a thin Ruby wrapper that exposes each Cloudflare
JavaScript object as a plain Ruby value.

Sister project: [`kazuph/homura`](https://github.com/kazuph/homura) —
the mruby/WASI version, with a custom Hono-like DSL. `homurabi` is the
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

`homurabi` is the brute-force answer to the question **"what does it
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
the diff against upstream by `rg "homurabi patch"`.

---

## Architecture at a glance

```
                ┌─────────────────────────────────────────────┐
                │           Cloudflare Workers (V8)           │
                │                                              │
    JS fetch   ─┼─▶ src/worker.mjs                              │
    event       │      • awaits req.text()                     │
                │      • forwards to globalThis.               │
                │        __HOMURABI_RACK_DISPATCH__            │
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
Mustermann + Rack::Protection, homurabi's adapter, and the user's
`app/hello.rb`. Cloudflare Workers `import`s that ESM from
`src/worker.mjs`, wrapped in a ~30 line Module Worker fetch handler.

---

## Upstream sources (everything is real)

Nothing in this repo is a clean-room reimplementation or a fake
"Sinatra-like" DSL. Every framework is the actual upstream gem, pulled
in-tree, patched only when Opal or the Workers sandbox forces the
issue. The patch sites are all marked with a `# homurabi patch:`
comment.

| Upstream | Version vendored | Path in this repo | Upstream URL |
|---|---|---|---|
| **Opal** (Ruby→JS compiler + corelib + stdlib) | `1.8.3.rc1` | `vendor/opal-gem/` | <https://github.com/opal/opal> |
| **janbiedermann/sinatra** (CRuby-3 compatible fork) | fork HEAD when vendored | `vendor/sinatra/` | <https://github.com/janbiedermann/sinatra> |
| **Rack** (patched copy shipped by the janbiedermann fork) | same | `vendor/rack/` | <https://github.com/rack/rack> |
| **Mustermann** (Sinatra's path matcher) | same | `vendor/mustermann/` | <https://github.com/sinatra/mustermann> |
| **Rack::Protection** | same | `vendor/rack/protection/` | <https://github.com/sinatra/sinatra/tree/main/rack-protection> |

`Gemfile` pins Opal via `gem 'opal', path: 'vendor/opal-gem'`, so the
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

The dispatcher installed on `globalThis.__HOMURABI_RACK_DISPATCH__` is
an `async function` that `await`s the Ruby `$call` result, so both
sync (plain Response) and async (Promise<Response>) paths flow through
the same entry point.

### src/worker.mjs — Module Worker entry

30 lines. Imports the compiled ESM, reads `req.text()` up front (so
the synchronous Opal dispatcher can stuff the body into `rack.input`
without needing to `await` anything later), and forwards to
`__HOMURABI_RACK_DISPATCH__`. Skips the body read for GET/HEAD/OPTIONS
so the hot path doesn't pay the cost.

### bin/compile-erb + views/ — build-time ERB precompiler

Cloudflare Workers refuses `eval` and `new Function`, which is exactly
what stock ERB runs at `template.result(binding)` time. A normal
Sinatra application would crash on the first `erb :index`.

homurabi's answer is to **precompile every ERB template to a plain
Ruby method at build time**, in CRuby, before Opal runs. The pipeline:

1. Templates live in `views/*.erb` as ordinary ERB source.
2. `bin/compile-erb` (a ~200 line CRuby script) tokenises each file
   looking for `<% %>` / `<%= %>` / `<%== %>` / `<%# %>` tags,
   emits a Ruby method body that concatenates the result into a
   local `_out` variable using `_out = _out + …` (Opal Strings are
   immutable; stock ERB's generated `<<` would blow up), and writes
   the whole thing to `build/homurabi_templates.rb`.
3. That file registers each template with a `HomurabiTemplates`
   module (`HomurabiTemplates.register(:index) do |locals| … end`)
   and reopens `Sinatra::Templates` to override `erb(name, ...)` so
   user code's `erb :index` transparently dispatches to the
   precompiled Proc via `instance.instance_exec(locals, &body)`.
4. The Opal build command picks the generated file up with
   `-I build -r homurabi_templates`, so it runs at Worker init time,
   installs the override, and is ready before the first request.

Result: user code writes stock Sinatra (`erb :index` with `@ivars` and
`<%= … %>` expressions), *never* knows Cloudflare's sandbox banned
eval, and still gets `<% @users.each do |user| %>…<% end %>` loops —
because every ERB tag is just Ruby that Opal compiled to JS ahead of
time. The generated `build/homurabi_templates.rb` is idempotent: run
`bin/compile-erb` any time you change a view.

The layout pattern works too: a route sets `@content = erb :index`
and then `erb :layout`, which is the canonical Sinatra two-file
rendering idiom.

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
(`gem 'opal', path: 'vendor/opal-gem'`) so there's no pre-release
download to worry about.

### Precompile ERB templates

```sh
ruby bin/compile-erb
# → writes build/homurabi_templates.rb with 1 Proc per view
```

Run this whenever anything under `views/` changes. The generated file
is regenerated in place and *only* the stdlib (plus a tiny ERB
tokenizer inside the script) is used — no gems outside Ruby core.

### Compile Ruby → JS

```sh
rm -f build/hello.no-exit.mjs build/opal.stderr.log
OPAL_PREFORK_DISABLE=1 bundle exec opal \
  -c -E --esm --no-source-map \
  -I lib -I vendor -I build \
  -r opal_patches -r cloudflare_workers -r homurabi_templates \
  -o build/hello.no-exit.mjs \
  app/hello.rb \
  2>build/opal.stderr.log
```

- `OPAL_PREFORK_DISABLE=1` because Opal's prefork scheduler swallows
  error lines.
- `-I lib -I vendor -I build` puts our patches, vendored gems, and the
  generated ERB table on the load path.
- `-r opal_patches -r cloudflare_workers -r homurabi_templates`
  installs the runtime shims, the Rack handler, and the precompiled
  views *before* `app/hello.rb` runs.

### Dev server

```sh
npx wrangler dev --port 8787 --ip 127.0.0.1
curl -i http://127.0.0.1:8787/
```

With `--local`, wrangler mocks D1/KV/R2 locally; without it, the dev
server hits the real bindings. Both work.

### Deploy

```sh
npx wrangler deploy
```

`wrangler.toml` declares the `[[d1_databases]]` / `[[kv_namespaces]]`
/ `[[r2_buckets]]` bindings; the deploy log prints them back.

### Provision the bindings (one-time)

```sh
npx wrangler d1 create homurabi-db
npx wrangler kv namespace create homurabi-kv
npx wrangler r2 bucket create homurabi-bucket

# seed a users table for the D1 demo routes
npx wrangler d1 execute homurabi-db --remote --command \
  "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);"
npx wrangler d1 execute homurabi-db --remote --command \
  "INSERT INTO users (name) VALUES ('alice'), ('bob'), ('kazu');"
```

Update `wrangler.toml` with the `database_id` / KV namespace `id` that
`wrangler` prints out.

---

## Directory layout

```
homurabi/
├── app/
│   └── hello.rb                 ← User Sinatra app. Plain Ruby, no CF imports.
├── views/
│   ├── layout.erb               ← Top-level HTML skeleton (<nav>, <footer>, …)
│   ├── index.erb                ← Home page (reads @users from D1)
│   ├── hello.erb                ← /hello/:name — classic <%= @name %>
│   └── about.erb                ← /about
├── bin/
│   └── compile-erb              ← Ruby script: views/*.erb → build/homurabi_templates.rb
├── build/
│   ├── hello.no-exit.mjs        ← Opal output (≈4 MiB, ≈580 KiB gzip). Gitignored.
│   └── homurabi_templates.rb    ← Auto-generated from views/. Picked up via -I build.
├── lib/
│   ├── cloudflare_workers.rb    ← Rack handler + CF binding wrappers. The only
│   │                              file that knows it's on Workers.
│   └── opal_patches.rb          ← Runtime shims (Module#deprecate_constant, URI,
│                                   Forwardable dot-path, encodings, SecureRandom).
├── src/
│   └── worker.mjs               ← 30-line Module Worker fetch handler.
├── vendor/
│   ├── opal-gem/                ← Opal 1.8.3.rc1 (full gem, 3 homurabi patches).
│   ├── sinatra/                 ← janbiedermann/sinatra fork. 6 homurabi patches
│   │                              in base.rb.
│   ├── rack/                    ← Rack + Rack::Protection (patched).
│   ├── mustermann/              ← Mustermann (patched).
│   ├── digest.rb, zlib.rb,      ← Minimal stubs for corelib gaps.
│   │   tempfile.rb, tilt.rb
│   └── bundle/                  ← bundler install target. Gitignored.
├── wrangler.toml                ← Worker config with D1 / KV / R2 bindings.
├── Gemfile                      ← Pins Opal via path: 'vendor/opal-gem'.
└── .artifacts/homurabi/          ← Not tracked. Holds the strict PLAN.md and
                                   per-phase evidence logs (phase 2 / phase 3).
```

Every patch file in `vendor/**` has an inline `# homurabi patch:`
comment, so the complete diff against upstream is:

```sh
rg "homurabi patch" vendor lib
```

---

## Project status & phases

The project follows a strict four-phase plan (see
`.artifacts/homurabi/PLAN.md`, not tracked in git). The current state
of each phase:

| Phase | Goal | Status |
|---|---|---|
| **Phase 0** | New repo + Opal → Workers boot with a plain `puts`. | ✅ shipped at commit `a09b399` |
| **Phase 1 R** | Pure Ruby Rack `lambda { \|env\| [200, …] }` returning real HTTP responses through a standard Rack handler. | ✅ shipped at commit `0dd4005` |
| **Phase 2** | Real `janbiedermann/sinatra` compiled and served through the Rack handler, full middleware chain (Rack::Protection headers), production `curl` returning actual Sinatra bodies, no ERB-in-dev-mode workarounds, no `request.body.read` stub. | ✅ shipped at commits `d74c329` / `e6d5f66` / `93fba66` — and the 5 1st-pass compromises (body stub, APP_ENV force, force_encoding no-op, Sinatra-side `next` patch, grep-ability) were all closed in a subsequent pass. |
| **Phase 3** | D1 / KV / R2 bindings callable from real Sinatra routes on Workers. | ✅ shipped at commits `ba0a772` / `4210de5`. All nine CRUD routes verified on production. |
| **Phase 4** | Evidence collection + マスター + Codex double review. | In progress. |

### Definition of Done (from PLAN.md §1.1)

- [x] `kazuph/homurabi` exists as a new GitHub repository.
- [x] `app/hello.rb` written in real CRuby syntax with `require 'sinatra/base'` and Sinatra DSL, **no JavaScript mixed in**.
- [x] Compiled to ESM via Opal and bundled into a Cloudflare Workers Module Worker.
- [x] Uses real `janbiedermann/sinatra` (no DSL re-implementation, no compatibility layer fakes).
- [x] D1 / KV / R2 bindings callable from Sinatra routes via the adapter's Ruby wrappers.
- [x] `wrangler dev` and `wrangler deploy` both serve the Sinatra app.

---

## Upstream policy — patches stay vendored

**None of the homurabi patches are submitted upstream**, and there
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
need upstream-style discussion and test coverage that homurabi
isn't going to own.

Every patch site is marked with a `# homurabi patch:` comment so the
diff against upstream is recoverable at any time via
`rg "homurabi patch"`. If you maintain Opal / Sinatra / Rack /
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

The plan document (`.artifacts/homurabi/PLAN.md`) lists the full
forbidden-fallback list and the review process (マスター + Codex
double review after every phase).

---

## Sister project

- [`kazuph/homura`](https://github.com/kazuph/homura) — Hono-like Ruby
  DSL on mruby/WASI for Cloudflare Workers. Lightweight, custom DSL,
  proven to work.
- [`kazuph/homurabi`](https://github.com/kazuph/homurabi) — this repo,
  real Ruby + real Sinatra via Opal. Ambitious, fallback-forbidden,
  a lot more bytes on the wire in exchange for the actual gem
  ecosystem.

## License

TBD. All vendored upstreams keep their original licenses — Opal is
MIT, Sinatra is MIT, Rack is MIT.
