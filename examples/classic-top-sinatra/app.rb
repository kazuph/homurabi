# frozen_string_literal: true
# Dogfood: classic-style `require 'sinatra'` + top-level routes (Phase 15-C).
require 'json'
require 'sinatra'

get '/dogfood' do
  content_type 'application/json'
  { 'ok' => true, 'mode' => 'classic-top-level' }.to_json
end

