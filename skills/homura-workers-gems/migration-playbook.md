# Existing-app migration playbook

Use this when the user wants to move an existing Sinatra app to Cloudflare Workers,
especially when only the backend should move first.

## Default strategy

1. **Move backend boundaries first**
   - Prefer `/api/*`, webhook handlers, cron, queue consumers, or other boundary-shaped routes.
   - Do not start with full SSR or template migration unless the user explicitly wants that.

2. **Keep Sinatra/Rack code shape**
   - Preserve route DSL, params handling, auth flow, and service objects where possible.
   - Remove or isolate Puma/Unicorn boot hooks, request-time filesystem reads, and other server-specific assumptions first.

3. **Create a Rake-first workflow immediately**
   - Even for an existing app, introduce `bundle exec rake build`, `rake dev`, and `rake deploy`.
   - Let Rake call `homura` and `wrangler` internally so the day-to-day workflow stays Ruby-shaped.

4. **Prefer JSON/API success before HTML/template success**
   - For backend-only migration, get API routes, auth, queue, cron, and webhooks working first.
   - Add ERB/template compilation only when the migration scope really needs SSR.

5. **Decide database strategy explicitly**
   - If the existing database stays, keep D1 out at first and call the existing backend/database boundary over HTTP or service bindings.
   - If the app can move to D1, then introduce `sequel-d1` and `homura db:migrate:*` as a separate step.

## Suggested AI workflow

1. Inventory the app's route surfaces and classify them into:
   - backend-only/API friendly
   - SSR/template dependent
   - filesystem/process dependent
2. Introduce a Rake wrapper layer before changing runtime behavior.
3. Port one backend slice end-to-end.
4. Validate that build/dev/deploy all run through Rake.
5. Only then expand to more routes or template rendering.

## Red flags

- ActiveRecord-heavy model layers tightly coupled to CRuby-only gems
- many Rack middlewares that assume long-lived server process semantics
- request-time `File.read` / template lookup / mutable local cache design
- large native-extension gem dependencies

When these appear, tell the user plainly that the migration should narrow scope
or stop at backend/API slices first instead of forcing a full automatic rewrite.
