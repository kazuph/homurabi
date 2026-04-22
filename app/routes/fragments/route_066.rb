# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 66 — demo /debug/mail
  post '/debug/mail' do
    gate = debug_mail_gate_response
    next gate if gate

    content_type 'text/html; charset=utf-8'

    @title = 'Debug — mail'
    @mail_from = homurabi_mail_from
    @form_to = params['to'].to_s.strip
    # urlencoded 本文で + がスペースにならず残るクライアントがあるため表示用に正規化
    @form_subject = params['subject'].to_s.strip.tr('+', ' ')
    @form_text = params['text'].to_s.tr('+', ' ')

    final_to = @form_to.empty? ? 'kazu.homma@gmail.com' : @form_to

    if homurabi_mail_from.empty?
      @error = 'HOMURABI_MAIL_FROM が未設定です。ドメイン onboarding 後に wrangler [vars] で verified の送信元アドレスを設定してください。'
    else
      mail = send_email
      available = !mail.nil? && mail.available?
      unless available
        @error = 'SEND_EMAIL バインディングが利用できません（wrangler.toml の [[send_email]] を確認）。'
      else
        vid = env['HTTP_CF_RAY'].to_s.split('-').first
        vid = Time.now.to_i.to_s if vid.nil? || vid.empty?
        # application/x-www-form-urlencoded の + / 省略ダッシュゆらぎを吸収
        fs = @form_subject.to_s.strip.tr('+', ' ')
        subject_line =
          if fs.empty?
            "homurabi Phase 17 test — #{vid}"
          elsif fs =~ /homurabi Phase 17 test.{0,3}Version\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
            fs
          else
            "#{fs} — #{vid}"
          end

        body_text =
          if @form_text.strip.empty?
            'This is a test mail from homurabi'
          else
            @form_text
          end

        begin
          result = mail.send(to: final_to, from: homurabi_mail_from, subject: subject_line, text: body_text).__await__
          mid_s = ''
          cf_raw = ''
          if `(#{result} == null || #{result} === undefined || #{result} === Opal.nil)`
            @error = 'SEND_EMAIL.send の戻りが null です。メールは送信されていません。'
          else
            mid_s = begin
              v = nil
              v ||= result['message_id'] if result.respond_to?(:[])
              v ||= result[:message_id] if result.respond_to?(:[])
              v ||= result['messageId'] if result.respond_to?(:[])
              v ||= result[:messageId] if result.respond_to?(:[])
              v.to_s
            rescue StandardError
              ''
            end
            cf_raw = begin
              (result['cf_send_result_json'] || result[:cf_send_result_json]).to_s
            rescue StandardError
              ''
            end
          end
          # message_id 空は「API が受付 ID を返していない」＝ダッシュボード 0 と整合しがちなので ok は偽。
          accepted = !mid_s.strip.empty?
          warn =
            accepted ? nil : 'message_id が空です。cf_send_result_json を確認してください。送信はキューに載っていない可能性があります。'
          # Opal Hash/JSON.generate can raise on nested types — build a minimal JSON string。
          # null 応答時は JSON を出さず @error のみ。
          unless @error
            @success_json =
              '{"ok":' + (accepted ? 'true' : 'false') +
              ',"message_id":' + mid_s.inspect +
              ',"cf_send_result_json":' + cf_raw.inspect +
              ',"to":' + final_to.inspect +
              ',"from":' + homurabi_mail_from.inspect +
              ',"subject":' + subject_line.inspect +
              (warn ? ',"warning":' + warn.inspect : '') + '}'
          end
        rescue Cloudflare::Email::Error => e
          code = e.code.to_s
          @error = "#{code}: #{e.message}".strip
        end
      end
    end

    erb :debug_mail
  end
