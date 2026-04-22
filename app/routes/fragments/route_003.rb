# await: true
# frozen_string_literal: true
# Route fragment 3 — demo /about
get '/about' do
  @title = 'About homurabi'
  @content = erb :about
  erb :layout
end
