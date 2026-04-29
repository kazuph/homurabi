# frozen_string_literal: true
require 'sinatra'

get '/' do
  'sinatra on Cloudflare Workers — try GET /frank-says'
end

get '/frank-says' do
  'Put this in your pipe & smoke it!'
end
