# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 55 — demo /demo/stream
get '/demo/stream' do
  unless foundations_demos_enabled?
    content_type 'application/json'
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  stream do |out|
    i = 0
    while i < 3
      out << "chunk #{i} @ #{Time.now.to_i}\n"
      out.sleep(0.5)
      i += 1
    end
    out << "done\n"
  end
end
