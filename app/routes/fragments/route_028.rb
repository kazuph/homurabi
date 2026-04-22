# await: true
# frozen_string_literal: true
# Route fragment 28 — test /test/scheduled/run
post '/test/scheduled/run' do
  content_type 'application/json'
  unless scheduled_demos_enabled?
    status 404
    next({ 'error' => 'scheduled demos disabled (set HOMURABI_ENABLE_SCHEDULED_DEMOS=1 in wrangler vars)' }.to_json)
  end
  cron = params['cron'].to_s
  if cron.empty?
    status 400
    next({ 'error' => 'missing cron query param (e.g. ?cron=*/5%20*%20*%20*%20*)' }.to_json)
  end
  # Use the same dispatcher the Workers runtime invokes. Pass the
  # JS env / ctx so D1 / KV writes hit the live bindings. The
  # dispatcher is async (it `__await__`s each job's body), so we
  # MUST `__await__` its return Promise before serialising the
  # result — otherwise the inner D1 / KV writes get torn down when
  # the HTTP response is sent. The literal `__await__` token is
  # what Opal scans for to emit a JS `await`.
  event  = Cloudflare::ScheduledEvent.new(cron: cron, scheduled_time: Time.now)
  result = App.dispatch_scheduled(event, env['cloudflare.env'], env['cloudflare.ctx'])
  result.merge('cron' => cron, 'registered_crons' => App.scheduled_jobs.map(&:cron)).to_json
end
