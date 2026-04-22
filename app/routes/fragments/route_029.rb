# frozen_string_literal: true
# Route fragment 29 — login /login
get '/login' do
  @title = 'Login — homura'
  @login_error = nil
  @content = erb :login
  erb :layout
end
