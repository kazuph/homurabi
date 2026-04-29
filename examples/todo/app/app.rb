# frozen_string_literal: true
require 'sinatra/base'
require 'cgi'

class App < Sinatra::Base
  helpers do
    def db
      env['cloudflare.DB'] or raise 'D1 binding missing (configure wrangler D1)'
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end
  end

  get '/' do
    @todos = db.execute('SELECT id, title, done, created_at FROM todos ORDER BY id')
    content_type 'text/html; charset=utf-8'
    erb :index
  end

  post '/todos' do
    title = params[:title].to_s.strip
    halt 400, 'title required' if title.empty?

    db.execute_insert(
      'INSERT INTO todos (title, done, created_at) VALUES (?, ?, ?)',
      [title, 0, Time.now.to_i]
    )
    redirect '/'
  end

  post '/todos/:id/toggle' do
    db.execute_insert('UPDATE todos SET done = 1 - done WHERE id = ?', [params[:id].to_i])
    redirect '/'
  end

  post '/todos/:id/delete' do
    db.execute_insert('DELETE FROM todos WHERE id = ?', [params[:id].to_i])
    redirect '/'
  end
end
