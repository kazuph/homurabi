# await: true
# frozen_string_literal: true
#
# A plain Sinatra application. Ported as faithfully as possible from
# the canonical Sinatra README / examples, so every line here reads
# the same as it would in any other Sinatra project. Nothing about
# Cloudflare Workers, Opal, or the Cloudflare bindings is visible in
# this file — the adapter lives entirely in `lib/cloudflare_workers.rb`.
#
# HTML pages go through real ERB templates stored under `views/*.erb`
# and rendered with the classic `erb :name` helper. homurabi's build
# pipeline precompiles those templates with `bin/compile-erb` so the
# Workers sandbox never has to call `eval` / `new Function` at runtime.

require 'json'
require 'sinatra/base'

class App < Sinatra::Base
  # ------------------------------------------------------------------
  # HTML pages — each route sets a few `@ivars` then renders an ERB
  # template from `views/`. Exactly like Sinatra's README example:
  #
  #     get '/' do
  #       erb :index
  #     end
  # ------------------------------------------------------------------

  get '/' do
    @title = 'Hello from Sinatra'
    db = env['cloudflare.DB']
    @users = db ? db.execute('SELECT id, name FROM users ORDER BY id').__await__ : []
    @content = erb :index
    erb :layout
  end

  get '/hello/:name' do
    @title = "Hello #{params['name']}"
    @name  = params['name']
    @content = erb :hello
    erb :layout
  end

  get '/about' do
    @title = 'About homurabi'
    @content = erb :about
    erb :layout
  end

  # A tiny JSON echo — still Sinatra DSL, just a different content type.
  post '/api/echo' do
    content_type 'application/json'
    request.body.rewind
    body = request.body.read
    "{\"echo\": \"#{body}\"}"
  end

  # ------------------------------------------------------------------
  # D1 / KV / R2 — Phase 3 routes. Async Sinatra on Opal needs one
  # ceremony: capture params BEFORE the first `.__await__`, because
  # Sinatra's `process_route` ensure block cleans `@params` the moment
  # the async block returns its Promise. Doing `key = params['key']` at
  # the top is idiomatic for async routes.
  # ------------------------------------------------------------------

  # D1 routes use the sqlite3-ruby compatible interface:
  #   db.execute(sql, binds)      → Array<Hash>
  #   db.get_first_row(sql, binds) → Hash or nil
  #   db.execute_insert(sql, binds) → meta Hash
  # Same calling convention as `SQLite3::Database` on CRuby.

  get '/d1/users' do
    content_type 'application/json'
    db = env['cloudflare.DB']
    db.execute('SELECT id, name FROM users ORDER BY id').__await__.to_json
  end

  get '/d1/users/:id' do
    content_type 'application/json'
    id = params['id'].to_i
    db = env['cloudflare.DB']
    row = db.get_first_row('SELECT id, name FROM users WHERE id = ?', [id]).__await__
    if row.nil?
      status 404
      { 'error' => 'not found', 'id' => id }.to_json
    else
      row.to_json
    end
  end

  post '/d1/users' do
    content_type 'application/json'
    begin
      payload = JSON.parse(request.body.read)
    rescue JSON::ParserError, StandardError => e
      status 400
      return { 'error' => 'invalid JSON body', 'detail' => e.message }.to_json
    end
    name = payload['name'].to_s
    db = env['cloudflare.DB']
    if name.empty?
      status 400
      { 'error' => 'name required' }.to_json
    else
      row = db.get_first_row('INSERT INTO users (name) VALUES (?) RETURNING id, name', [name]).__await__
      status 201
      row.to_json
    end
  end

  get '/kv/:key' do
    content_type 'application/json'
    key = params['key']
    kv  = env['cloudflare.KV']
    value = kv.get(key).__await__
    if value.nil?
      status 404
      { 'error' => 'not found', 'key' => key }.to_json
    else
      { 'key' => key, 'value' => value }.to_json
    end
  end

  put '/kv/:key' do
    content_type 'application/json'
    key  = params['key']
    body = request.body.read
    kv   = env['cloudflare.KV']
    kv.put(key, body).__await__
    status 201
    { 'key' => key, 'value' => body, 'stored' => true }.to_json
  end

  delete '/kv/:key' do
    content_type 'application/json'
    key = params['key']
    kv  = env['cloudflare.KV']
    kv.delete(key).__await__
    { 'key' => key, 'deleted' => true }.to_json
  end

  # Serve binary assets (images, etc.) from R2. Uses BinaryBody which
  # passes the R2 ReadableStream directly to the JS Response, bypassing
  # Opal's String encoding. This is a normal Sinatra route — no JS in
  # worker.mjs, no backtick here.
  get '/images/:key' do
    key    = params['key']
    bucket = env['cloudflare.BUCKET']
    obj    = bucket.get_binary(key).__await__
    if obj.nil?
      status 404
      'not found'
    else
      obj  # BinaryBody — build_js_response detects and streams directly
    end
  end

  get '/r2/:key' do
    content_type 'application/json'
    key    = params['key']
    bucket = env['cloudflare.BUCKET']
    obj    = bucket.get(key).__await__
    if obj.nil?
      status 404
      { 'error' => 'not found', 'key' => key }.to_json
    else
      {
        'key'  => obj['key'],
        'body' => obj['body'],
        'etag' => obj['etag'],
        'size' => obj['size']
      }.to_json
    end
  end

  put '/r2/:key' do
    content_type 'application/json'
    key             = params['key']
    body            = request.body.read rescue ''
    content_type_in = request.env['CONTENT_TYPE'] || 'application/octet-stream'
    bucket          = env['cloudflare.BUCKET']
    bucket.put(key, body, content_type_in).__await__
    status 201
    { 'key' => key, 'size' => body.bytesize, 'stored' => true }.to_json
  end

  delete '/r2/:key' do
    content_type 'application/json'
    key    = params['key']
    bucket = env['cloudflare.BUCKET']
    bucket.delete(key).__await__
    { 'key' => key, 'deleted' => true }.to_json
  end
end

run App
