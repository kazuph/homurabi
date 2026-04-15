# await: true
# A plain Sinatra application.

require 'json'
require 'sinatra/base'

class App < Sinatra::Base
  get '/' do
    "hello from real sinatra on opal\n" \
    "method: #{request.request_method}\n" \
    "path:   #{request.path_info}\n"
  end

  get '/hello/:name' do
    "hello, #{params['name']}!\n"
  end

  post '/api/echo' do
    content_type 'application/json'
    body = request.body.read rescue ''
    "{\"echo\": \"#{body}\"}"
  end

  # --- D1 ---------------------------------------------------------------
  #
  # NOTE on async routes: Sinatra's `process_route` has an `ensure` block
  # that deletes the route-captured keys from `@params` right after the
  # block returns. When a route block is compiled with `# await: true`
  # it returns a Promise *immediately* (before any `await` actually
  # fires), so `process_route`'s cleanup runs before the async body
  # resumes — and `params['id']` is already gone. The fix is to capture
  # the values into local variables at the very start of the block,
  # before the first `.__await__`.

  get '/d1/users' do
    content_type 'application/json'
    db = env['cloudflare.DB']
    rows = db.prepare('SELECT id, name FROM users ORDER BY id').all.__await__
    rows.to_json
  end

  get '/d1/users/:id' do
    content_type 'application/json'
    id = params['id'].to_i
    db = env['cloudflare.DB']
    row = db.prepare('SELECT id, name FROM users WHERE id = ?').bind(id).first.__await__
    if row.nil?
      status 404
      { 'error' => 'not found', 'id' => id }.to_json
    else
      row.to_json
    end
  end

  post '/d1/users' do
    content_type 'application/json'
    payload = JSON.parse(request.body.read) rescue {}
    name = payload['name'].to_s
    db = env['cloudflare.DB']
    if name.empty?
      status 400
      { 'error' => 'name required' }.to_json
    else
      result = db.prepare('INSERT INTO users (name) VALUES (?) RETURNING id, name').bind(name).first.__await__
      status 201
      result.to_json
    end
  end

  # --- KV ---------------------------------------------------------------

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
    body = request.body.read rescue ''
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

  # --- R2 ---------------------------------------------------------------

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
