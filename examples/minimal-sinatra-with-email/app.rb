# frozen_string_literal: true
require 'sinatra/cloudflare_workers'

class App < Sinatra::Base
  get '/' do
    content_type 'text/plain; charset=utf-8'
    'minimal sinatra with email — no __await__ anywhere!'
  end

  post '/send' do
    content_type 'application/json'

    mailer = Cloudflare::Email.new(env.SEND_EMAIL)
    result = mailer.send(
      to:      params['to'],
      from:    'noreply@example.com',
      subject: params['subject'],
      text:    params['text'],
      html:    params['html']
    )

    { ok: true, message_id: result['id'] }.to_json
  rescue Cloudflare::Email::Error => e
    status 502
    { ok: false, error: e.message }.to_json
  end
end

run App
