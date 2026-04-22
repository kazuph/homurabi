# await: true
# frozen_string_literal: true
# Route fragment 66 — demo /debug/mail
get '/debug/mail' do
  gate = debug_mail_gate_response
  next gate if gate

  @title = 'Debug — mail'
  @mail_from = homurabi_mail_from
  @form = Homurabi::DebugMailController.parse_form_params(params, default_to: true)
  @result = nil
  erb :debug_mail
end
