# frozen_string_literal: true
# Route fragment 32 — login /chat
get '/chat' do
  # /chat's body is async (load_chat_history is auto-awaited), so
  # `redirect` (which throws :halt) would surface as
  # `UncaughtThrowError: uncaught throw "halt"` past the async
  # boundary. Set Location on the response (captured into
  # `js_headers` by build_js_response before any await), then
  # return a 2-element `[status, body]` tuple that the JS
  # override in `lib/cloudflare_workers.rb` recognises.
  unless current_session_user
    response['Location'] = "/login?return_to=#{Rack::Utils.escape('/chat')}"
    next [302, '']
  end

  @title = 'homurabi /chat — Workers AI'
  @primary_model  = App::CHAT_MODELS[:primary]
  @fallback_model = App::CHAT_MODELS[:fallback]
  @session_id = normalize_session_id(params['session'])
  @history = ai_demos_enabled? ? load_chat_history(@session_id) : []
  @content = erb :chat
  erb :layout
end
