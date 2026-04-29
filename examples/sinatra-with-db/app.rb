# await: all, call, fetch, get_first_row, open, run, sleep
# frozen_string_literal: true

require 'sinatra'
require 'sequel'

get '/' do
  content_type 'text/plain; charset=utf-8'
  'sinatra + sequel-d1 on Cloudflare Workers — try GET /users'
end

get '/users' do
  content_type 'application/json; charset=utf-8'
  # Prefer the Ruby D1 wrapper from cloudflare-workers-runtime.
  # Raw `env['cloudflare.env'].DB` is also valid for duck-typed `d1:`.
  d1 = env['cloudflare.DB']
  unless d1
    status 503
    next({ 'error' => 'D1 binding missing (configure wrangler D1)' }.to_json)
  end

  db = Sequel.connect(adapter: :d1, d1: d1)
  rows = db[:users].order(:id).all
  { 'users' => rows }.to_json
end

