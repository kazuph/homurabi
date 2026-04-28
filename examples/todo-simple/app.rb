# frozen_string_literal: true
#
# todo-simple — the smallest homura example.
#
# Single file, no `views/` directory, no D1, no migrations. The HTML
# is built from heredoc strings right inside the routes, and the data
# lives in a Ruby array on the class. The Worker isolate's lifetime
# IS the data's lifetime — restart wrangler dev and it's gone.
#
# Reach for `examples/todo` (D1, no ORM) or `examples/todo-orm`
# (D1 through Sequel) when you need persistence.

require 'sinatra/cloudflare_workers'

class App < Sinatra::Base
  TODOS = []
  NEXT_ID = [1]

  helpers do
    def page(body)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>todo-simple</title>
          <style>
            body { font-family: system-ui, sans-serif; max-width: 32em; margin: 3em auto; padding: 0 1em; }
            h1 { font-size: 1.4rem; }
            form.add { display: flex; gap: .5rem; margin: 1rem 0; }
            form.add input[type=text] { flex: 1; padding: .4rem; }
            ul { list-style: none; padding: 0; }
            li { display: flex; align-items: center; gap: .5rem; padding: .3rem 0; border-bottom: 1px solid #eee; }
            li.done span { color: #888; text-decoration: line-through; }
            button { cursor: pointer; }
          </style>
        </head>
        <body>
          #{body}
        </body>
        </html>
      HTML
    end

    def todos_html
      return '<p>No todos yet — add one above.</p>' if TODOS.empty?
      items = TODOS.map do |t|
        done_class = t[:done] ? ' class="done"' : ''
        label = t[:done] ? '↩' : '✓'
        title = Rack::Utils.escape_html(t[:title])
        <<~LI
          <li#{done_class}>
            <form action="/todos/#{t[:id]}/toggle" method="post" style="display:inline">
              <button type="submit">#{label}</button>
            </form>
            <span>#{title}</span>
            <form action="/todos/#{t[:id]}/delete" method="post" style="display:inline">
              <button type="submit">×</button>
            </form>
          </li>
        LI
      end
      "<ul>#{items.join}</ul>"
    end
  end

  get '/' do
    page <<~HTML
      <h1>todo-simple</h1>
      <p>One file, no <code>views/</code>, no ORM, no migrations.</p>
      <form class="add" action="/todos" method="post">
        <input type="text" name="title" placeholder="What needs doing?" required autofocus>
        <button type="submit">Add</button>
      </form>
      #{todos_html}
    HTML
  end

  post '/todos' do
    title = params[:title].to_s.strip
    unless title.empty?
      TODOS << { id: NEXT_ID[0], title: title, done: false }
      NEXT_ID[0] += 1
    end
    redirect '/'
  end

  post '/todos/:id/toggle' do
    todo = TODOS.find { |t| t[:id] == params[:id].to_i }
    todo[:done] = !todo[:done] if todo
    redirect '/'
  end

  post '/todos/:id/delete' do
    TODOS.reject! { |t| t[:id] == params[:id].to_i }
    redirect '/'
  end
end

run App
