# frozen_string_literal: true
require 'sinatra'

# Simplest possible email sender:
#   - In dev (`*.localhost` / 127.0.0.1) we POST to a local mailpit Send API.
#   - In production we use Cloudflare Email Workers via the SEND_EMAIL binding.
# A `HOMURA_MAIL_ALLOWLIST` secret (comma-separated) gates which `to` addresses
# the production path will actually deliver to — anything else is silently
# dropped with a success-shaped response, so the demo never leaks who's
# allowed. Forks of this example can leave the secret unset to send to anyone.

helpers do
  def dev_host?
    h = request.host.to_s
    h == 'localhost' || h == '127.0.0.1' || h.end_with?('.localhost')
  end

  def cf_env_var(name)
    cf_env = env['cloudflare.env']
    return '' unless cf_env
    `(#{cf_env}[#{name}] || '')`.to_s.strip
  end

  def mail_allowed?(to)
    return true if dev_host?
    list = cf_env_var('HOMURA_MAIL_ALLOWLIST').split(',').map { |s| s.strip.downcase }.reject(&:empty?)
    return true if list.empty?
    list.include?(to.to_s.strip.downcase)
  end
end

get '/' do
  content_type 'text/plain; charset=utf-8'
  'minimal sinatra with email — POST /send (to, from, subject, text|html)'
end

post '/send' do
  content_type 'application/json'
  to = params['to'].to_s.strip

  unless mail_allowed?(to)
    # Silent success: we don't reveal whether the address is on the allowlist.
    return({ 'ok' => true, 'message_id' => nil, 'note' => 'queued' }.to_json)
  end

  if dev_host?
    # mailpit HTTP send API.
    payload = {
      'From' => { 'Email' => params['from'] || 'noreply@example.com' },
      'To'   => [{ 'Email' => to }],
      'Subject' => params['subject'].to_s,
      'Text'    => params['text'].to_s,
      'HTML'    => params['html'].to_s
    }.to_json
    resp = Cloudflare::HTTP.fetch(
      'http://127.0.0.1:8025/api/v1/send',
      method: 'POST',
      headers: { 'content-type' => 'application/json' },
      body: payload
    )
    if resp.ok?
      { 'ok' => true, 'message_id' => 'mailpit' }.to_json
    else
      status 502
      { 'ok' => false, 'error' => "mailpit #{resp.status}" }.to_json
    end
  else
    # Production: Cloudflare Email Workers (SEND_EMAIL binding is already a
    # Cloudflare::Email instance — no extra `.new` wrapper needed).
    mailer = env['cloudflare.SEND_EMAIL']
    from = cf_env_var('HOMURA_MAIL_FROM')
    from = params['from'] || 'noreply@example.com' if from.empty?
    result = mailer.send(
      to:      to,
      from:    from,
      subject: params['subject'].to_s,
      text:    params['text'],
      html:    params['html']
    )
    { 'ok' => true, 'message_id' => result['message_id'] }.to_json
  end
rescue Cloudflare::Email::Error => e
  status 502
  { 'ok' => false, 'error' => e.message }.to_json
end

