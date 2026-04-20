# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
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
