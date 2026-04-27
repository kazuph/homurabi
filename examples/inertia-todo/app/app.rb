# frozen_string_literal: true
require 'sinatra/cloudflare_workers'
require 'sequel'
require 'json'
require 'rack/utils'

class App < Sinatra::Base
  ASSETS_VERSION = '2'

  helpers do
    def db
      d1 = env['cloudflare.DB']
      raise 'D1 binding missing (configure wrangler D1)' unless d1
      Sequel.connect(adapter: :d1, d1: d1)
    end

    def todos
      db[:todos].order(:id).all.map do |row|
        {
          id: row[:id],
          title: row[:title],
          done: row[:done].to_i == 1,
          created_at: row[:created_at]
        }
      end
    end

    def inertia_request?
      request.env['HTTP_X_INERTIA'] == 'true'
    end

    def render_inertia(component, props)
      page = {
        component: component,
        props: props,
        url: request.fullpath,
        version: ASSETS_VERSION
      }

      if inertia_request?
        content_type 'application/json'
        headers 'X-Inertia' => 'true', 'Vary' => 'X-Inertia'
        return page.to_json
      end

      # erb 側で Rack::Utils.escape_html してから data-page 属性に埋めるため、生 JSON をそのまま渡す。
      @page_json = page.to_json
      erb :layout, layout: false
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
            # ignore malformed JSON bodies
          end
        end
      end
      result
    end
  end

  # Inertia: assets version mismatch on GET → 409 + X-Inertia-Location
  before do
    if inertia_request? && request.get?
      client_version = request.env['HTTP_X_INERTIA_VERSION']
      if client_version && client_version != ASSETS_VERSION
        headers 'X-Inertia-Location' => request.fullpath
        halt 409
      end
    end
  end

  get '/' do
    render_inertia('Todos', { todos: todos })
  end

  post '/todos' do
    body = parse_body_params
    title = body['title'].to_s.strip
    unless title.empty?
      db[:todos].insert(title: title, done: 0, created_at: Time.now.to_i)
    end
    redirect to('/'), 303
  end

  post '/todos/:id/toggle' do
    id = params['id'].to_i
    db[:todos].where(id: id).update(Sequel.lit('done = 1 - done'))
    redirect to('/'), 303
  end

  post '/todos/:id/delete' do
    id = params['id'].to_i
    db[:todos].where(id: id).delete
    redirect to('/'), 303
  end
end
