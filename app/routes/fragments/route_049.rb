# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 49 — demo /demo/faraday
  get '/demo/faraday' do
    content_type 'application/json'
    unless foundations_demos_enabled?
      status 404
      next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
    end
    client = Faraday.new(url: 'https://api.ipify.org') do |c|
      c.request :json
      c.response :json
      c.headers['user-agent'] = 'homurabi-phase11a/1.0'
    end
    res = client.get('/', { 'format' => 'json' }).__await__
    {
      'demo'        => 'Faraday.new(url:) { request :json; response :json }',
      'status'      => res.status,
      'success'     => res.success?,
      'reason'      => res.reason_phrase,
      'body'        => res.body,  # parsed Hash thanks to :json middleware
      'headers_ct'  => res.headers['content-type']
    }.to_json
  end
