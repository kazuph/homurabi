# A plain Sinatra application.

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
end

run App
