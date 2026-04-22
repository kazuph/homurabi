# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 66 — demo /debug/mail
post '/debug/mail' do
  gate = debug_mail_gate_response
  next gate if gate

  content_type 'text/html; charset=utf-8'

  @title = 'Debug — mail'
  @mail_from = homurabi_mail_from
  @result = Homurabi::DebugMailController.send_test_mail(params, env, self)
  @form = @result[:form]
  erb :debug_mail
end
