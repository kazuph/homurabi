# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 9 — Sinatra::Scheduled
#
# A Sinatra extension that adds a class-level `schedule` DSL so user
# apps can register Cloudflare Workers Cron Trigger handlers in the
# same file as the HTTP routes. Modelled after the `whenever` /
# `sidekiq-cron` style of inline declaration but mapped to the
# Cloudflare Workers `scheduled(event, env, ctx)` lifecycle.
#
#     class App < Sinatra::Base
#       register Sinatra::Scheduled
#
#       schedule '*/5 * * * *', name: 'heartbeat' do |event|
#         db = env['cloudflare.DB']
#         db.execute_insert(
#           'INSERT INTO heartbeats (cron, scheduled_at) VALUES (?, ?)',
#           [event.cron, event.scheduled_time.to_i]
#         ).__await__
#       end
#
#       schedule '0 */1 * * *' do |event|
#         # hourly cleanup
#       end
#     end
#
# Each `schedule` call appends a job to `App.scheduled_jobs`. When the
# Workers runtime fires the cron trigger, `src/worker.mjs` invokes
# `globalThis.__HOMURABI_SCHEDULED_DISPATCH__`, which is installed by
# `Cloudflare::Scheduled.install_dispatcher` and forwards the event to
# this extension's `dispatch_scheduled` class method.
#
# The dispatcher matches `event.cron` (the literal cron string from
# `wrangler.toml [triggers] crons`) against each registered job's
# pattern. Matching is exact-string by default — Cloudflare Workers
# always passes back one of the cron strings declared in wrangler.toml,
# never a derived expression — but a `match:` proc may be supplied for
# fuzzy matching during local testing.
#
# Each block runs in a fresh anonymous Sinatra subclass instance so
# `env`, `helpers`, `settings`, and `logger` are available. The block
# receives a `Cloudflare::ScheduledEvent` argument exposing `.cron`,
# `.scheduled_time` (Time), and `.type`.
#
# `wait_until(promise)` is a thin wrapper over the Workers
# `ctx.waitUntil(...)` API so a job can hand back a long-running
# promise without blocking the dispatcher.

require 'time'

module Sinatra
  module Scheduled
    # A registered scheduled job. Captured at class-definition time;
    # the block is invoked once per matching cron firing.
    #
    # The block is held both as a Proc (for introspection and the
    # unit tests that just call .block.call) and as an UnboundMethod
    # bound onto a fresh ScheduledContext at fire time. The
    # UnboundMethod path is what makes `__await__` inside the block
    # actually await on the Workers runtime — Opal's `# await: true`
    # mode promotes `define_method`'d methods to async functions, but
    # NOT free-standing blocks called via `Proc#call` / `instance_exec`.
    # Sinatra itself uses the same trick for its routes (see
    # `Sinatra::Base.generate_method`).
    class Job
      attr_reader :cron, :name, :block, :unbound_method, :match_proc, :file, :line

      def initialize(cron:, name:, block:, unbound_method: nil, match_proc: nil, file: nil, line: nil)
        @cron = cron.to_s.freeze
        @name = (name || cron).to_s.freeze
        @block = block
        @unbound_method = unbound_method
        @match_proc = match_proc
        @file = file
        @line = line
      end

      # True when this job should fire for the given cron string.
      # The default policy is exact string match, which is what the
      # Workers runtime guarantees. A custom :match proc lets tests
      # use loose matching (e.g. always run, regex match) without
      # touching wrangler.toml.
      def matches?(cron_string)
        return @match_proc.call(cron_string) if @match_proc
        @cron == cron_string.to_s
      end
    end

    module ClassMethods
      # Returns the (per-class) array of registered Job instances.
      # Subclassing inherits the parent's jobs by reference — explicit
      # `schedule` calls in the subclass append to its own private list
      # so a subclass cannot mutate its parent's schedule.
      def scheduled_jobs
        @scheduled_jobs ||= []
      end

      # Register a cron block.
      #
      #   schedule '*/5 * * * *' do |event|
      #     ...
      #   end
      #
      # Options:
      #   :name      — human label for logging (default: the cron string)
      #   :match     — proc(cron_string) returning truthy if this job
      #                should fire. Defaults to exact-string equality.
      def schedule(cron, name: nil, match: nil, &block)
        raise ArgumentError, 'schedule requires a block' unless block
        cron_str = cron.to_s
        raise ArgumentError, 'cron expression must be non-empty' if cron_str.empty?
        # Cheap structural sanity-check: 5 or 6 whitespace-separated
        # fields. Cloudflare allows the standard 5-field form.
        fields = cron_str.split(/\s+/)
        unless [5, 6].include?(fields.length)
          raise ArgumentError, "cron expression must have 5 or 6 fields, got #{fields.length}: #{cron_str.inspect}"
        end

        loc = block.respond_to?(:source_location) ? block.source_location : nil
        file = loc.is_a?(Array) ? loc[0] : nil
        line = loc.is_a?(Array) ? loc[1] : nil

        # Convert the block into an UnboundMethod bound to
        # ScheduledContext. `define_method` is what triggers Opal's
        # `# await: true` machinery to wrap the body as an async
        # function — without this step, `kv.get(...).__await__` would
        # never resolve because the surrounding scope isn't async.
        # See the Job class comment for the full rationale.
        method_name = "__scheduled_#{cron_str.object_id}_#{scheduled_jobs.length}".to_sym
        ScheduledContext.send(:define_method, method_name, &block)
        unbound = ScheduledContext.instance_method(method_name)
        ScheduledContext.send(:remove_method, method_name)

        scheduled_jobs << Job.new(
          cron: cron_str,
          name: name,
          block: block,
          unbound_method: unbound,
          match_proc: match,
          file: file,
          line: line
        )
      end

      # Returns all jobs that match the given cron string.
      def scheduled_jobs_for(cron_string)
        scheduled_jobs.select { |j| j.matches?(cron_string) }
      end

      # Dispatcher entry point — called by Cloudflare::Scheduled with
      # a Cloudflare::ScheduledEvent and the JS env / ctx objects.
      # Returns a Hash with `fired`, `total`, `errors` for diagnostics.
      def dispatch_scheduled(event, js_env = nil, js_ctx = nil)
        jobs = scheduled_jobs_for(event.cron)
        results = []
        i = 0
        # `while` instead of `each` keeps the per-iteration begin/rescue
        # straightforward under Opal's `# await: true` translation —
        # each iteration's `__await__` is awaited inline rather than
        # through a yielded async block (which has had subtle issues
        # with rescue propagation in Opal).
        while i < jobs.length
          job = jobs[i]
          start = Time.now.to_f
          begin
            # invoke_scheduled_job is an async method (it's defined
            # inside a `# await: true` file and may itself await an
            # inner Promise from the user block). Calling it returns
            # a Promise — we MUST `__await__` it here so:
            #   (a) downstream code sees fully-applied side effects,
            #   (b) the rescue below catches Promise rejections that
            #       propagate as Ruby exceptions.
            #
            # The literal `__await__` token is what Opal scans for to
            # emit a JS `await`; calling a helper that internally does
            # `__await__` is NOT enough, because the helper's return
            # value is itself a Promise that the caller would have to
            # `__await__` again.
            promise = invoke_scheduled_job(job, event, js_env, js_ctx)
            if `(#{promise} != null && typeof #{promise}.then === 'function')`
              promise.__await__
            end
            results << {
              'name'     => job.name,
              'cron'     => job.cron,
              'ok'       => true,
              'duration' => Time.now.to_f - start
            }
          rescue ::Exception => e
            results << {
              'name'     => job.name,
              'cron'     => job.cron,
              'ok'       => false,
              'error'    => "#{e.class}: #{e.message}",
              'duration' => Time.now.to_f - start
            }
          end
          i += 1
        end
        { 'fired' => results.size, 'total' => scheduled_jobs.size, 'results' => results }
      end

      private

      # Build a tiny Rack-shaped env so the block has the same
      # `env['cloudflare.DB']` / `KV` / `BUCKET` accessors that HTTP
      # routes use. We deliberately do NOT spin up a full Sinatra
      # request — there is no HTTP request, no params, no response.
      def invoke_scheduled_job(job, event, js_env, js_ctx)
        env = build_scheduled_env(event, js_env, js_ctx)
        ctx = ScheduledContext.new(env, event, js_ctx)
        # Prefer the UnboundMethod path (Opal `# await: true` aware).
        # Fall back to instance_exec only when there is no unbound
        # method — e.g. when a job was constructed manually in tests.
        result = if job.unbound_method
                   bound = job.unbound_method.bind(ctx)
                   if job.block.arity.zero?
                     bound.call
                   else
                     bound.call(event)
                   end
                 else
                   ctx.instance_exec(event, &job.block)
                 end
        # When the block body uses `__await__` internally, Opal compiles
        # the wrapping method as an async JS function, so its return
        # value is a JS Promise. We MUST `await` that promise here for
        # two reasons:
        #
        #   1. Side effects (D1 / KV writes) need to complete before
        #      `dispatch_scheduled` records the job as `ok`.
        #   2. Without the await, a `raise` inside the block silently
        #      becomes a rejected promise and our outer `rescue` in
        #      dispatch_scheduled never catches it — the bug would
        #      surface as scheduled jobs reporting ok=true even when
        #      they raised.
        #
        # Sync blocks return plain Ruby values; we use a JS-level
        # thenable check before calling `.__await__` to avoid invoking
        # the await on a non-Promise (which would crash).
        if `(#{result} != null && typeof #{result}.then === 'function')`
          # The literal `__await__` token is required at every async
          # boundary — calling a helper that does `__await__` is NOT
          # equivalent because the helper's return value is itself a
          # Promise that callers would need to `__await__` again.
          result.__await__
        else
          result
        end
      end

      def build_scheduled_env(event, js_env, js_ctx)
        env = {
          'cloudflare.scheduled'      => true,
          'cloudflare.event'          => event,
          'cloudflare.cron'           => event.cron,
          'cloudflare.scheduled_time' => event.scheduled_time,
          'cloudflare.env'            => js_env,
          'cloudflare.ctx'            => js_ctx
        }
        if js_env
          js_db = `#{js_env} && #{js_env}.DB`
          js_kv = `#{js_env} && #{js_env}.KV`
          js_r2 = `#{js_env} && #{js_env}.BUCKET`
          env['cloudflare.DB']     = ::Cloudflare::D1Database.new(js_db)  if `#{js_db} != null`
          env['cloudflare.KV']     = ::Cloudflare::KVNamespace.new(js_kv) if `#{js_kv} != null`
          env['cloudflare.BUCKET'] = ::Cloudflare::R2Bucket.new(js_r2)    if `#{js_r2} != null`
        end
        env
      end
    end

    # ScheduledContext is the `self` inside a `schedule do ... end`
    # block. It deliberately mirrors only the slice of Sinatra's
    # request scope that makes sense outside an HTTP context: env,
    # logger, settings, and Cloudflare binding helpers (db / kv /
    # bucket).
    class ScheduledContext
      attr_reader :env, :event

      def initialize(env, event, js_ctx)
        @env = env
        @event = event
        @js_ctx = js_ctx
      end

      def db;     env['cloudflare.DB'];     end
      def kv;     env['cloudflare.KV'];     end
      def bucket; env['cloudflare.BUCKET']; end

      # Forward a long-running promise to the Workers runtime so the
      # job can return immediately while the work continues.
      # Mirrors `ctx.waitUntil(promise)` in the JS API.
      def wait_until(promise)
        return promise if @js_ctx.nil?
        js_ctx = @js_ctx
        `#{js_ctx}.waitUntil(#{promise})`
        promise
      end

      # Minimal logger so jobs can puts without crashing in non-Workers
      # test environments. Falls back to STDOUT.
      def logger
        @logger ||= LoggerShim.new
      end

      class LoggerShim
        %i[info warn error debug].each do |lvl|
          define_method(lvl) { |msg| $stdout.puts("[scheduled.#{lvl}] #{msg}") }
        end
      end
    end

    # Sinatra calls registered(app) with the user's Sinatra::Base
    # subclass when `register Sinatra::Scheduled` is evaluated.
    def self.registered(app)
      app.extend(ClassMethods)
    end
  end

  # Auto-register on Sinatra::Base so plain `schedule` works for both
  # classic-style and modular-style apps. Other Sinatra extensions
  # (e.g. Sinatra::JwtAuth) follow the same convention.
  Base.register Scheduled if defined?(::Sinatra::Base)
end
