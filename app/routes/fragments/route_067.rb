# await: true
# frozen_string_literal: true
# Route fragment 67 — demo /debug/mail
post '/debug/mail' do
  gate = debug_mail_gate_response
  next gate if gate

  content_type 'text/html; charset=utf-8'

  @title = 'Debug — mail'
  @mail_from = homurabi_mail_from

  ctx = Homurabi::DebugMailController.prepare_send(params, env, self)
  if ctx[:error_result]
    @result = ctx[:error_result]
  else
    begin
      raw = ctx[:mail].send(
        to: ctx[:final_to],
        from: ctx[:mail_from],
        subject: ctx[:subject_line],
        text: ctx[:text_body],
        html: ctx[:html_body]
      ).__await__
      @result = Homurabi::DebugMailController.after_send_success(raw, ctx)
    rescue Cloudflare::Email::Error => e
      @result = Homurabi::DebugMailController.after_send_failure(e, ctx)
    end
  end

  @form = @result[:form]
  erb :debug_mail
end
