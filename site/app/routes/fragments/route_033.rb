# frozen_string_literal: true
# Route fragment 33 — api /api/chat/health
get '/api/chat/health' do
  content_type 'application/json'
  {
    'ok'             => true,
    'demos_enabled'  => ai_demos_enabled?,
    'ai_bound'       => ai_binding?,
    'kv_bound'       => !kv.nil?,
    'primary_model'  => App::CHAT_MODELS[:primary],
    'fallback_model' => App::CHAT_MODELS[:fallback]
  }.to_json
end
