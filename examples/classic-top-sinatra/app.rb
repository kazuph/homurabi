# frozen_string_literal: true
# Dogfood: classic-style `require 'sinatra'` + top-level routes (Phase 15-C).
require 'json'
require 'sinatra'

get '/' do
  content_type 'text/plain; charset=utf-8'
  "classic-top-sinatra on Cloudflare Workers\n" \
    "  GET /dogfood   → JSON proof of classic top-level DSL\n"
end

get '/dogfood' do
  content_type 'application/json'
  { 'ok' => true, 'mode' => 'classic-top-level' }.to_json
end

