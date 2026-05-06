# frozen_string_literal: true
# Route fragment 36 — api /api/chat/messages
delete "/api/chat/messages" do
  content_type "application/json"
  gate = ai_demos_block_or_nil
  next gate if gate
  auth_status, auth_result = authenticate_or_401
  next auth_status, auth_result if auth_status
  session_id = normalize_session_id(params["session"])
  clear_chat_history(session_id)
  { "ok" => true, "session" => session_id, "cleared" => true }.to_json
end
