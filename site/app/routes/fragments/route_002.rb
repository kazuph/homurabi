# frozen_string_literal: true
# Route fragment 2 — demo /hello/:name
get '/hello/:name' do
  @title = "Hello #{params['name']}"
  @name  = params['name']
  @content = erb :hello
  erb :layout
end
