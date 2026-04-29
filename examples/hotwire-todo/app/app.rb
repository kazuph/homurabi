# frozen_string_literal: true

require 'sinatra/base'

class App < Sinatra::Base
  helpers do
    # D1 binding (Cloudflare::D1Database). Provides a sqlite3-ruby compatible
    # surface: `execute`, `execute_insert`, `get_first_row`, etc.
    #
    # NOTE: keep the body as a bare `env['cloudflare.DB']`. Wrapping it in
    # `... or raise ...` turns the AST into a `:or` node and auto-await stops
    # inferring the return type as `Cloudflare::D1Database`, which silently
    # breaks `db.execute(...)` (the JS Promise leaks through).
    def db
      env['cloudflare.DB']
    end

    def turbo_stream_request?
      accept = request.env['HTTP_ACCEPT'].to_s
      accept.include?('text/vnd.turbo-stream.html')
    end

    def render_todo_li(t)
      erb :_todo, layout: false, locals: { t: t }
    end

    def render_form
      erb :_form, layout: false
    end

    # Build a turbo-stream body composed of the requested actions.
    # Each entry is one of [:append, :replace, :remove] and renders a single
    # `<turbo-stream>` element using the @t / @id state set on the route.
    def render_turbo_streams(*actions)
      actions.map { |action| render_turbo_stream(action) }.join
    end

    def render_turbo_stream(action)
      case action
      when :append
        li_html = render_todo_li(@t)
        %(<turbo-stream action="append" target="todos-list"><template>#{li_html}</template></turbo-stream>)
      when :replace_form
        form_html = render_form
        %(<turbo-stream action="replace" target="todo-form"><template>#{form_html}</template></turbo-stream>)
      when :replace
        li_html = render_todo_li(@t)
        %(<turbo-stream action="replace" target="todo-#{@t['id']}"><template>#{li_html}</template></turbo-stream>)
      when :remove
        %(<turbo-stream action="remove" target="todo-#{@id}"></turbo-stream>)
      else
        raise ArgumentError, "unknown turbo-stream action: #{action.inspect}"
      end
    end
  end

  get '/' do
    @todos = db.execute('SELECT id, title, done, created_at FROM todos ORDER BY id')
    content_type 'text/html; charset=utf-8'
    erb :index, layout: :layout
  end

  post '/todos' do
    title = (params['title'] || '').to_s.strip
    return redirect '/' if title.empty?

    meta = db.execute_insert(
      'INSERT INTO todos (title, done, created_at) VALUES (?, ?, ?)',
      [title, 0, Time.now.to_i]
    )
    new_id = meta['last_row_id']

    if turbo_stream_request?
      @t = { 'id' => new_id, 'title' => title, 'done' => 0 }
      content_type 'text/vnd.turbo-stream.html; charset=utf-8'
      render_turbo_streams(:append, :replace_form)
    else
      redirect '/'
    end
  end

  post '/todos/:id/toggle' do
    id = params['id'].to_i
    # Flip the boolean integer in a single UPDATE so we avoid an extra async
    # round-trip to fetch-then-update.
    db.execute('UPDATE todos SET done = 1 - done WHERE id = ?', [id])
    # Use `db.execute(...).first` instead of `db.get_first_row(...)` because
    # the build-time auto-await pass currently leaves a bare `db.get_first_row`
    # un-awaited when it follows another `db.execute(...)` in the same block,
    # and the calling code then trips over a raw JS Promise.
    rows = db.execute('SELECT id, title, done, created_at FROM todos WHERE id = ?', [id])
    row = rows && rows.first

    if turbo_stream_request?
      content_type 'text/vnd.turbo-stream.html; charset=utf-8'
      if row.nil?
        ''
      else
        @t = row
        render_turbo_stream(:replace)
      end
    else
      redirect '/'
    end
  end

  post '/todos/:id/delete' do
    id = params['id'].to_i
    db.execute('DELETE FROM todos WHERE id = ?', [id])

    if turbo_stream_request?
      @id = id
      content_type 'text/vnd.turbo-stream.html; charset=utf-8'
      render_turbo_stream(:remove)
    else
      redirect '/'
    end
  end
end

