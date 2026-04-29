# frozen_string_literal: true
# Route fragment 31 — login /logout
get '/logout' do
  response.delete_cookie(App::SESSION_COOKIE_NAME, path: '/')
  redirect '/'
end
