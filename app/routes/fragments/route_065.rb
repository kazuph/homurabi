# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 65 — demo /debug/mail
  get '/debug/mail' do
    debug_mail_require_kazuph!
    @title = 'Debug — mail'
    @mail_from = homurabi_mail_from
    @form_to = (params['to'] || 'kazu.homma@gmail.com').to_s
    @form_subject = params['subject'].to_s
    @form_text = params['text'].to_s
    erb :debug_mail
  end
