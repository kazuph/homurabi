# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 66 — demo /debug/mail
  post '/debug/mail' do
    debug_mail_require_kazuph!
    content_type 'text/html; charset=utf-8'

    @title = 'Debug — mail'
    @mail_from = homurabi_mail_from
    @form_to = params['to'].to_s.strip
    @form_subject = params['subject'].to_s.strip
    @form_text = params['text'].to_s

    final_to = @form_to.empty? ? 'kazu.homma@gmail.com' : @form_to

    if homurabi_mail_from.empty?
      @error = 'HOMURABI_MAIL_FROM が未設定です。ドメイン onboarding 後に wrangler [vars] で verified の送信元アドレスを設定してください。'
      return erb :debug_mail
    end

    mail = send_email
    unless mail&.available?
      @error = 'SEND_EMAIL バインディングが利用できません（wrangler.toml の [[send_email]] を確認）。'
      return erb :debug_mail
    end

    vid = env['HTTP_CF_RAY'].to_s.split('-').first
    vid = Time.now.to_i.to_s if vid.nil? || vid.empty?
    subject_line =
      if @form_subject.empty?
        "homurabi Phase 17 test — #{vid}"
      else
        "#{@form_subject} — #{vid}"
      end

    body_text =
      if @form_text.strip.empty?
        'This is a test mail from homurabi'
      else
        @form_text
      end

    begin
      result = mail.send(to: final_to, from: homurabi_mail_from, subject: subject_line, text: body_text).__await__
      rid = result && (result[:message_id] || result['message_id'])
      @success_json = JSON.pretty_generate({
        'ok'           => true,
        'message_id'   => rid,
        'to'           => final_to,
        'from'         => homurabi_mail_from,
        'subject'      => subject_line
      })
    rescue Cloudflare::Email::Error => e
      code = e.code.to_s
      @error = "#{code}: #{e.message}".strip
    end

    erb :debug_mail
  end
