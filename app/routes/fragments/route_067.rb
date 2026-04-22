# frozen_string_literal: true
# Route fragment 67 — demo /debug/mail
post '/debug/mail' do
  gate = debug_mail_gate_response
  next gate if gate

  content_type 'text/html; charset=utf-8'

  @title = 'Debug — mail'
  @mail_from = homura_mail_from

  mail = send_email
  ctx = Homura::DebugMailController.prepare_send(params, env, self, mail)
  if ctx[:error_result]
    @result = ctx[:error_result]
  else
    begin
      raw = mail.send(
        to: ctx[:final_to],
        from: ctx[:mail_from],
        subject: ctx[:subject_line],
        text: ctx[:text_body],
        html: ctx[:html_body]
      )
      @result = Homura::DebugMailController.after_send_success(raw, ctx)
    rescue Cloudflare::Email::Error => e
      @result = Homura::DebugMailController.after_send_failure(e, ctx)
    end
  end

  @form = @result[:form]
  erb :debug_mail
end
