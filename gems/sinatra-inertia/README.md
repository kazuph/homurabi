# sinatra-inertia

A Sinatra extension that implements the full **Inertia.js v2** wire protocol —
page-object responses, version-mismatch detection, partial reloads,
deferred / lazy / always / optional / merge props, encrypted history, 303
redirect promotion, and error/flash session sweeps.

Pure Sinatra-compatible: depends only on `sinatra` and `rack`. Runs on
MRI Ruby and on the [homura](https://github.com/kazuph/homura) Cloudflare
Workers + Opal stack.

## Why "驚き最小"?

Two principles drove the API:

1. **Routes render pages.** Application code should read like ordinary
   Sinatra: `render 'Pages/Show', record: record`. The Inertia protocol stays
   in the extension.
2. **Class-level config uses Sinatra nouns.** Use `set :page_version`,
   `set :page_layout`, and `share_props do ... end`. The older `inertia_*`
   names still work for existing apps.

## Installation

```ruby
# Gemfile
gem 'sinatra'
gem 'sinatra-inertia'
```

## Hello, Inertia

```ruby
require 'sinatra'
require 'sinatra/inertia'

register Sinatra::Inertia

set :page_version, -> { ENV.fetch('ASSETS_VERSION', '1') }

get '/' do
  render 'Pages/Hello', name: 'world'
end
```

```erb
<!-- views/layout.erb -->
<!doctype html>
<html>
<head>
  <title>App</title>
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <div id="app" data-page="<%= @page_json %>"></div>
  <script type="module" src="/assets/app.js"></script>
</body>
</html>
```

## Public API

### Helpers (per-request)

| helper | purpose |
|---|---|
| `render 'Comp', props_hash` | Render an Inertia response (HTML on first hit, JSON on Inertia visit). |
| `render 'Comp', key: value` | Keyword-prop form of the same page render. |
| `page_request?` | True when `X-Inertia: true` header is present. |
| `page_errors(payload = nil)` | Read or write validation errors that survive one redirect. |
| `clear_history!` | Mark the next response's history as cleared. |
| `encrypt_history!` | Mark the next response's history as encrypted. |
| `always`, `defer`, `optional`, `lazy`, `merge` | Prop wrappers for Inertia v2 transport modes. |

Compatibility aliases remain available: `inertia`, `render(inertia: ...)`,
`inertia_request?`, `inertia_errors`, `inertia_clear_history!`,
`inertia_encrypt_history!`, and `Inertia.defer` / `Inertia.merge` / etc.

### Class-level DSL

| DSL | purpose |
|---|---|
| `set :page_version, -> { ... }` | Asset version. Mismatch on Inertia GET → 409 + `X-Inertia-Location`. |
| `set :page_layout, :layout` | ERB layout used for full-page rendering (default `:layout`). |
| `set :inertia_encrypt_history, true` | Default `encryptHistory: true` on every page. |
| `share_props do … end` | Block whose return Hash is merged into every page's props. |

Compatibility aliases remain available: `set :inertia_version`,
`set :inertia_layout`, and `inertia_share do ... end`.

### Prop wrappers (Inertia v2 transport modes)

```ruby
render 'Page',
  todos:  -> { Todo.all },                        # plain lazy
  csrf:   always { csrf_token },                  # always sent
  stats:  defer(group: 'meta') { stats },         # excluded from initial response
  filter: optional { params[:f] },                # only on partial-reload request
  feed:   merge(page_items)                       # client-side array merge
```

| wrapper | semantics |
|---|---|
| bare `Proc`/`->` | resolved every request when included; partial-reload aware. |
| `always { … }` | always included, even on partials that omit it. |
| `defer(group:) { … }` | excluded on initial visit; client refetches in second roundtrip. |
| `optional { … }` | only resolved when explicitly requested via `X-Inertia-Partial-Data`. |
| `lazy { … }` | alias of `optional` (Inertia v1 name). |
| `merge(value)` | sent as a merge prop (`mergeProps` array on page object). Honours `X-Inertia-Reset: prop1,prop2` (Inertia 2.0) — reset props are emitted as plain values and dropped from `mergeProps`. |

## Protocol features

* **Initial GET** — full HTML response. The layout sees `@page_json` (HTML-
  escaped JSON) and `@page` (raw Hash).
* **Inertia visit** — `X-Inertia: true` request gets `Content-Type:
  application/json`, `X-Inertia: true`, `Vary: X-Inertia`, body = page object.
* **Version mismatch** — Inertia GET with mismatched `X-Inertia-Version` →
  `409 Conflict` + `X-Inertia-Location: <url>`. Client hard-reloads.
* **303 redirect promotion** — non-GET 302 responses are auto-promoted to
  303 so the browser follows with GET.
* **Partial reloads** — `X-Inertia-Partial-Component` + `X-Inertia-Partial-Data`
  / `X-Inertia-Partial-Except` headers narrow which props are resolved.
* **Encrypted history / clear history** — set per-app via setting or per-route
  via `encrypt_history!` / `clear_history!`.
* **Errors session** — `page_errors(field: 'msg')` survives one redirect
  and is automatically swept on render.

## Validation pattern (no 422, no client state)

```ruby
post '/todos' do
  if params[:title].to_s.strip.empty?
    page_errors title: "can't be blank"
    redirect back  # 303 by middleware; Inertia client follows
  else
    Todo.create(params)
    redirect '/', 303
  end
end

get '/' do
  render 'Todos/Index',
    todos: Todo.all,
    values: { title: params[:title] }
end
```

The error payload appears on the next render's `props.errors` and is
swept from the session — exactly the experience described in the
"modern monolith" articles, no 422 dance, no client state machine.

## Compatibility

* MRI Ruby ≥ 3.1
* Sinatra ≥ 3.0 (incl. 4.x)
* Rack ≥ 2.0 (incl. 3.x)
* homura (Opal on Cloudflare Workers) — vendored Sinatra/Rack work as-is,
  but **set `:logging, false`** in Workers builds because
  `Rack::CommonLogger` uses `String#gsub!` (Opal does not implement
  mutable string methods).

## License

MIT.
