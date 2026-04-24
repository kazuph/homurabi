# Gem map

## `opal-homura`

- Published name: `opal-homura`
- `require` path stays `opal`
- Use for Opal compiler/runtime compatibility in this stack

## `homura-runtime`

- Published name: `homura-runtime`
- Core runtime and build surface
- Owns `homura build`
- Owns Workers bindings exposed in Rack env like `env['cloudflare.DB']`

## `sinatra-homura`

- Published name: `sinatra-homura`
- Sinatra integration layer
- Owns `homura new` and `homura erb:compile`
- Includes JWT / Scheduled / Queue extensions used by homura

## `sequel-d1`

- Published name: `sequel-d1`
- Sequel adapter for Cloudflare D1
- Owns `homura db:migrate:*`

## Docs entrypoints

- Human overview: `README.md`
- Machine-readable summary: `public/llms.txt`
- Setup guide: `skills/homura-workers-gems/quick-start.md`
- Common pitfalls: `skills/homura-workers-gems/gotchas.md`
- Runtime internals: `docs/TOOLCHAIN_CONTRACT.md`
