# await: all, call, fetch, get_first_row, open, run, sleep
# frozen_string_literal: true

require 'sinatra/base'
require 'sequel'
require 'cgi'

class App < Sinatra::Base
  helpers do
    def db
      return nil unless d1
      Sequel.connect(adapter: :d1, d1: d1)
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end
  end

  get '/' do
    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    @todos = conn[:todos].order(:id).all
    content_type 'text/html; charset=utf-8'
    erb :index, layout: :layout
  end

  post '/todos' do
    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    title = (params['title'] || '').to_s.strip
    if title.empty?
      redirect '/'
      next
    end

    conn[:todos].insert(title: title, done: 0, created_at: Time.now.to_i)
    redirect '/'
  end

  post '/todos/:id/toggle' do
    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    id = params['id'].to_i
    # Flip the boolean integer in a single UPDATE so we avoid an extra async round-trip.
    conn[:todos].where(id: id).update(done: Sequel.lit('1 - done'))
    redirect '/'
  end

  post '/todos/:id/delete' do
    conn = db
    if conn.nil?
      status 503
      content_type 'text/plain; charset=utf-8'
      next 'D1 binding missing (configure wrangler D1)'
    end

    id = params['id'].to_i
    conn[:todos].where(id: id).delete
    redirect '/'
  end
end
