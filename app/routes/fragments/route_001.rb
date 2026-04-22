# frozen_string_literal: true
# Route fragment 1 — demo /
get '/' do
  @title = 'Hello from Sinatra'
  @users = db ? db.execute('SELECT id, name FROM users ORDER BY id') : []
  @content = erb :index
  erb :layout
end
