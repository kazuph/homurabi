# frozen_string_literal: true
require 'sinatra/cloudflare_workers'
require 'sinatra'

get '/' do
  content_type 'text/plain; charset=utf-8'
  'minimal sinatra on cloudflare workers'
end

run Sinatra::Application
