# frozen_string_literal: true
# Route fragment 27 — test /test/scheduled
get '/test/scheduled' do
  content_type 'application/json'
  unless scheduled_demos_enabled?
    status 404
    next { 'error' => 'scheduled demos disabled (set HOMURABI_ENABLE_SCHEDULED_DEMOS=1 in wrangler vars)' }.to_json
  end
  {
    'jobs' => App.scheduled_jobs.map do |job|
      {
        'name' => job.name,
        'cron' => job.cron,
        'file' => job.file,
        'line' => job.line
      }
    end
  }.to_json
end
