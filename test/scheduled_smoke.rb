# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 9 — Scheduled Workers (Cron Triggers) smoke tests.
#
# Exercises the full dispatch chain that `src/worker.mjs#scheduled`
# uses, but plugged into the test harness directly so we can run it
# under Node without booting wrangler:
#
#   1. Sinatra::Scheduled DSL — `schedule '*/5 * * * *' do …`
#      registers exactly one Job per call, with the right cron string,
#      source location, and exact-string match policy.
#   2. Multiple `schedule` calls on the same app accumulate (no
#      shadowing).
#   3. `dispatch_scheduled` only fires jobs whose cron equals
#      `event.cron`; other jobs are skipped silently.
#   4. The block runs inside a ScheduledContext that exposes the same
#      `db` / `kv` / `bucket` helpers HTTP routes use (with whatever
#      env wrappers the dispatcher built).
#   5. `Cloudflare::Scheduled.dispatch(...)` — the test entry point —
#      resolves the registered Sinatra app from
#      `Rack::Handler::CloudflareWorkers.app` and forwards.
#   6. `Cloudflare::ScheduledEvent.from_js` correctly converts the JS
#      `event.scheduledTime` epoch-millis into a Ruby Time.
#   7. Cron expression validation rejects malformed input loudly.
#   8. Custom `match:` proc lets a job catch arbitrary cron strings
#      (used for "always-run" test schedules).
#   9. Block exceptions are caught per job and reported in the
#      results array (one bad job doesn't kill the others).
#
# Usage:
#   npm run test:scheduled
#   npm test                # full suite (smoke + http + crypto + jwt + scheduled)

require 'json'
require 'time'
require 'sinatra/base'
require 'cloudflare_workers'
require 'sinatra/scheduled'

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    result = block.call
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stdout.puts "  FAIL  #{label}"
    end
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts "  CRASH #{label} — #{e.class}: #{e.message}"
  end

  def self.report
    total = @passed + @failed
    $stdout.puts ''
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts 'Failures:'
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# ---------------------------------------------------------------------
# Test app — every test creates a fresh anonymous Sinatra subclass so
# the `@scheduled_jobs` registry is isolated per case.
# ---------------------------------------------------------------------
def fresh_app
  Class.new(Sinatra::Base) do
    register Sinatra::Scheduled
  end
end

# Each test below uses `app.dispatch_scheduled(...).__await__` to get
# back the result Hash. The trailing `__await__` is required because
# `dispatch_scheduled` is async (its inner per-job calls go through
# Opal `# await: true`); without it, callers would inspect the
# returned Promise instead of the resolved value. The literal
# `__await__` token is what Opal scans for to emit a JS `await`.

$stdout.puts '=== homurabi Phase 9 — Scheduled smoke ==='
$stdout.puts ''

# ---------------------------------------------------------------------
# 1. DSL registration
# ---------------------------------------------------------------------
$stdout.puts '--- DSL registration ---'

SmokeTest.assert('schedule registers exactly one job') {
  app = fresh_app
  app.schedule('*/5 * * * *') { |e| e }
  app.scheduled_jobs.length == 1
}

SmokeTest.assert('schedule captures cron string verbatim') {
  app = fresh_app
  app.schedule('0 */1 * * *') { |e| e }
  app.scheduled_jobs.first.cron == '0 */1 * * *'
}

SmokeTest.assert('schedule accepts :name option') {
  app = fresh_app
  app.schedule('*/5 * * * *', name: 'heartbeat') { |e| e }
  app.scheduled_jobs.first.name == 'heartbeat'
}

SmokeTest.assert('schedule defaults :name to the cron string') {
  app = fresh_app
  app.schedule('*/5 * * * *') { |e| e }
  app.scheduled_jobs.first.name == '*/5 * * * *'
}

SmokeTest.assert('multiple schedule calls accumulate (no shadowing)') {
  app = fresh_app
  app.schedule('*/5 * * * *') { |e| e }
  app.schedule('0 */1 * * *') { |e| e }
  app.schedule('0 0 * * *')   { |e| e }
  app.scheduled_jobs.map(&:cron) == ['*/5 * * * *', '0 */1 * * *', '0 0 * * *']
}

# ---------------------------------------------------------------------
# 2. Cron expression validation
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Cron expression validation ---'

SmokeTest.assert('schedule rejects empty cron string') {
  app = fresh_app
  raised = false
  begin
    app.schedule('') { |e| e }
  rescue ArgumentError
    raised = true
  end
  raised
}

SmokeTest.assert('schedule rejects 4-field cron expression (too few)') {
  app = fresh_app
  raised = false
  begin
    app.schedule('*/5 * * *') { |e| e }
  rescue ArgumentError
    raised = true
  end
  raised
}

SmokeTest.assert('schedule rejects 7-field cron expression (too many)') {
  app = fresh_app
  raised = false
  begin
    app.schedule('* * * * * * *') { |e| e }
  rescue ArgumentError
    raised = true
  end
  raised
}

SmokeTest.assert('schedule rejects no-block call') {
  app = fresh_app
  raised = false
  begin
    app.schedule('*/5 * * * *')
  rescue ArgumentError
    raised = true
  end
  raised
}

SmokeTest.assert('schedule accepts 6-field (with seconds) cron expression') {
  app = fresh_app
  app.schedule('0 */5 * * * *') { |e| e }
  app.scheduled_jobs.first.cron == '0 */5 * * * *'
}

SmokeTest.assert('schedule rejects non-callable match:') {
  app = fresh_app
  raised = false
  begin
    app.schedule('*/5 * * * *', match: 'not-a-proc') { |e| e }
  rescue ArgumentError
    raised = true
  end
  raised
}

# ---------------------------------------------------------------------
# 3. Dispatch — exact match
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Dispatch: exact-string match ---'

SmokeTest.assert('dispatch_scheduled fires only the matching job') {
  app = fresh_app
  fired = []
  app.schedule('*/5 * * * *', name: 'a') { |e| fired << ['a', e.cron] }
  app.schedule('0 */1 * * *', name: 'b') { |e| fired << ['b', e.cron] }

  event = Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)
  result = app.dispatch_scheduled(event).__await__

  fired == [['a', '*/5 * * * *']] && result['fired'] == 1 && result['total'] == 2
}

SmokeTest.assert('dispatch_scheduled passes the ScheduledEvent into the block') {
  app = fresh_app
  captured = nil
  app.schedule('*/5 * * * *') { |e| captured = e }
  t = Time.at(1_700_000_000)
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: t)).__await__
  captured.cron == '*/5 * * * *' && captured.scheduled_time.to_i == 1_700_000_000
}

SmokeTest.assert('dispatch_scheduled with no matching job returns fired=0') {
  app = fresh_app
  app.schedule('*/5 * * * *') { |e| e }
  result = app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: 'nonexistent', scheduled_time: Time.now)).__await__
  result['fired'] == 0 && result['total'] == 1
}

SmokeTest.assert('dispatch_scheduled records job name + ok=true on success') {
  app = fresh_app
  app.schedule('*/5 * * * *', name: 'heartbeat') { |e| e }
  result = app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  r = result['results'].first
  r['name'] == 'heartbeat' && r['ok'] == true && r['cron'] == '*/5 * * * *'
}

# ---------------------------------------------------------------------
# 4. ScheduledContext — db / kv / bucket helpers
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- ScheduledContext helpers ---'

SmokeTest.assert('block self exposes #db / #kv / #bucket helpers') {
  app = fresh_app
  saw = {}
  app.schedule('*/5 * * * *') do |_event|
    saw[:db_method]     = respond_to?(:db)
    saw[:kv_method]     = respond_to?(:kv)
    saw[:bucket_method] = respond_to?(:bucket)
    saw[:env_method]    = respond_to?(:env)
  end
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  saw[:db_method] && saw[:kv_method] && saw[:bucket_method] && saw[:env_method]
}

SmokeTest.assert('block sees env[\'cloudflare.cron\']') {
  app = fresh_app
  seen = nil
  app.schedule('*/5 * * * *') { |_e| seen = env['cloudflare.cron'] }
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  seen == '*/5 * * * *'
}

SmokeTest.assert('block sees env[\'cloudflare.scheduled\'] = true') {
  app = fresh_app
  seen = nil
  app.schedule('*/5 * * * *') { |_e| seen = env['cloudflare.scheduled'] }
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  seen == true
}

SmokeTest.assert('db helper returns Cloudflare::D1Database wrapper when DB binding present') {
  app = fresh_app
  saw = nil
  app.schedule('*/5 * * * *') { |_e| saw = db }

  fake_db = `({ prepare: function(){} })`
  fake_env = `({ DB: #{fake_db} })`
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now), fake_env).__await__
  saw.is_a?(Cloudflare::D1Database)
}

SmokeTest.assert('kv helper returns Cloudflare::KVNamespace wrapper when KV binding present') {
  app = fresh_app
  saw = nil
  app.schedule('*/5 * * * *') { |_e| saw = kv }
  fake_kv = `({ get: function(){} })`
  fake_env = `({ KV: #{fake_kv} })`
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now), fake_env).__await__
  saw.is_a?(Cloudflare::KVNamespace)
}

# ---------------------------------------------------------------------
# 5. ScheduledEvent.from_js — JS event conversion
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- ScheduledEvent.from_js ---'

SmokeTest.assert('from_js converts cron + scheduledTime correctly') {
  js_event = `({ cron: '*/5 * * * *', scheduledTime: 1700000000000, type: 'scheduled' })`
  ev = Cloudflare::ScheduledEvent.from_js(js_event)
  ev.cron == '*/5 * * * *' && ev.scheduled_time.to_i == 1_700_000_000 && ev.type == 'scheduled'
}

SmokeTest.assert('from_js handles missing scheduledTime by defaulting to now') {
  js_event = `({ cron: '*/5 * * * *', type: 'scheduled' })`
  ev = Cloudflare::ScheduledEvent.from_js(js_event)
  ev.cron == '*/5 * * * *' && ev.scheduled_time.is_a?(Time)
}

# ---------------------------------------------------------------------
# 6. Cloudflare::Scheduled.dispatch — public entry point
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Cloudflare::Scheduled.dispatch ---'

SmokeTest.assert('Scheduled.dispatch routes to the registered app') {
  app = fresh_app
  fired = []
  app.schedule('*/5 * * * *') { |e| fired << e.cron }
  Cloudflare::Scheduled.app = app
  begin
    Cloudflare::Scheduled.dispatch('*/5 * * * *', Time.now).__await__
  ensure
    Cloudflare::Scheduled.app = nil
  end
  fired == ['*/5 * * * *']
}

SmokeTest.assert('Scheduled.dispatch raises when no app is registered') {
  Cloudflare::Scheduled.app = nil
  if defined?(Rack::Handler::CloudflareWorkers)
    begin
      saved_app = Rack::Handler::CloudflareWorkers.instance_variable_get(:@app)
      Rack::Handler::CloudflareWorkers.instance_variable_set(:@app, nil)
    rescue StandardError
      saved_app = nil
    end
  end
  raised = false
  begin
    Cloudflare::Scheduled.dispatch('*/5 * * * *').__await__
  rescue StandardError
    raised = true
  end
  if defined?(Rack::Handler::CloudflareWorkers) && saved_app
    Rack::Handler::CloudflareWorkers.instance_variable_set(:@app, saved_app)
  end
  raised
}

# ---------------------------------------------------------------------
# 7. Custom :match proc
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Custom :match proc ---'

SmokeTest.assert(':match proc lets a job catch any cron expression') {
  app = fresh_app
  fired = []
  app.schedule('* * * * *', match: ->(_cron) { true }) { |e| fired << e.cron }
  app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: 'unrelated-cron', scheduled_time: Time.now)).__await__
  fired == ['unrelated-cron']
}

SmokeTest.assert(':match proc returning false skips the job') {
  app = fresh_app
  fired = []
  app.schedule('* * * * *', match: ->(_cron) { false }) { |e| fired << e.cron }
  result = app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  fired.empty? && result['fired'] == 0
}

# ---------------------------------------------------------------------
# 8. Per-job error isolation
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- Per-job error isolation ---'

SmokeTest.assert('an exception in one job does not stop sibling jobs') {
  app = fresh_app
  fired = []
  app.schedule('*/5 * * * *', name: 'a') { |_e| raise 'kaboom' }
  app.schedule('*/5 * * * *', name: 'b') { |_e| fired << :b }
  result = app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  ok_a = result['results'].find { |r| r['name'] == 'a' }
  ok_b = result['results'].find { |r| r['name'] == 'b' }
  fired == [:b] && ok_a['ok'] == false && ok_a['error'].include?('kaboom') && ok_b['ok'] == true
}

SmokeTest.assert('failed job records error class + message') {
  app = fresh_app
  app.schedule('*/5 * * * *') { |_e| raise ArgumentError, 'bad stuff' }
  result = app.dispatch_scheduled(Cloudflare::ScheduledEvent.new(cron: '*/5 * * * *', scheduled_time: Time.now)).__await__
  r = result['results'].first
  r['ok'] == false && r['error'].include?('ArgumentError') && r['error'].include?('bad stuff')
}

# ---------------------------------------------------------------------
# 9. JS dispatcher hook installation
# ---------------------------------------------------------------------
$stdout.puts ''
$stdout.puts '--- JS dispatcher hook ---'

SmokeTest.assert('globalThis.__HOMURABI_SCHEDULED_DISPATCH__ is installed') {
  installed = `typeof globalThis.__HOMURABI_SCHEDULED_DISPATCH__ === 'function'`
  installed
}

SmokeTest.assert('JS dispatcher hook resolves to the Sinatra app via Rack handler') {
  # Plug a fresh app in via the explicit override and call the JS
  # hook the way `src/worker.mjs#scheduled` would.
  app = fresh_app
  fired = []
  app.schedule('*/5 * * * *', name: 'js-hook') { |e| fired << e.cron }
  Cloudflare::Scheduled.app = app
  result = nil
  begin
    js_event = `({ cron: '*/5 * * * *', scheduledTime: 1700000000000, type: 'scheduled' })`
    promise = `globalThis.__HOMURABI_SCHEDULED_DISPATCH__(#{js_event}, null, null)`
    result = promise.__await__
  ensure
    Cloudflare::Scheduled.app = nil
  end
  fired == ['*/5 * * * *'] && result['fired'] == 1
}

success = SmokeTest.report
`process.exit(#{success ? 0 : 1})`
