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
  unless d1
    status 503
    next({ 'error' => 'D1 binding missing (configure wrangler D1)' }.to_json)
  end

  db = Sequel.connect(adapter: :d1, d1: d1)
  rows = db[:users].order(:id).all
  { 'users' => rows }.to_json
end
