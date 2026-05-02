# frozen_string_literal: true
require 'sinatra/base'
require 'sinatra/inertia'
require 'sequel'
require 'json'

class App < Sinatra::Base
  register Sinatra::Inertia

  set :page_version, ENV.fetch('ASSETS_VERSION', '3')
  set :page_layout, :layout
  set :logging, false   # Rack::CommonLogger uses gsub! (not Opal-compatible)
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET', 'a' * 64)

  share_props do
    {
      flash: flash_payload,
      csrfToken: csrf_token
    }
  end

  helpers do
    def db
      raise 'D1 binding missing' unless d1
      Sequel.connect(adapter: :d1, d1: d1)
    end

    def todos
      db[:todos].order(Sequel.desc(:id)).all.map do |row|
        {
          id: row[:id],
          title: row[:title],
          description: row[:description],
          done: row[:done].to_i == 1,
          created_at: row[:created_at]
        }
      end
    end

    def todo_stats
      all = db[:todos].all
      {
        total: all.size,
        done: all.count { |r| r[:done].to_i == 1 },
        pending: all.count { |r| r[:done].to_i == 0 }
      }
    end

    def parse_body_params
      result = {}
      result.merge!(params) if params.is_a?(Hash)
      ctype = request.env['CONTENT_TYPE'].to_s
      if ctype.include?('application/json')
        body = request.body.read
        unless body.empty?
          begin
            json = JSON.parse(body)
            result.merge!(json) if json.is_a?(Hash)
          rescue JSON::ParserError
            # ignore malformed JSON
          end
        end
      end
      result
    end

    def flash_payload
      flash = session.delete(:_flash)
      flash || {}
    end

    def set_flash(payload)
      session[:_flash] = payload
    end
  end

  get '/' do
    render 'Todos/Index',
           todos: -> { todos },
           stats: defer(group: 'meta') { todo_stats }
  end

  post '/todos' do
    body = parse_body_params
    title = body['title'].to_s.strip
    description = body['description'].to_s.strip

    errors = {}
    errors[:title] = 'title is required' if title.empty?
    errors[:title] = 'title must be 40 chars or less' if title.length > 40
    errors[:description] = 'description must be 200 chars or less' if description.length > 200

    unless errors.empty?
      page_errors errors
      # Re-render the same page with the previous values so the form is preserved.
      set_flash(values: { title: title, description: description })
      redirect to('/'), 303
    end

    db[:todos].insert(
      title: title,
      description: description.empty? ? nil : description,
      done: 0,
      created_at: Time.now.to_i
    )
    set_flash(notice: 'Todo added')
    redirect to('/'), 303
  end

  post '/todos/:id/toggle' do
    db[:todos].where(id: params['id'].to_i).update(Sequel.lit('done = 1 - done'))
    redirect to('/'), 303
  end

  post '/todos/:id/delete' do
    db[:todos].where(id: params['id'].to_i).delete
    set_flash(notice: 'Todo deleted')
    redirect to('/'), 303
  end
end
