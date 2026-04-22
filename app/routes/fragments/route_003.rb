# frozen_string_literal: true
# Route fragment 3 — demo /about
get '/about' do
  @title = 'About homura'
  @content = erb :about
  erb :layout
end
