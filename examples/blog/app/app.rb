# frozen_string_literal: true
require 'sinatra/base'
require 'time'

class App < Sinatra::Base
  set :views, File.expand_path('../views', __dir__)

  helpers do
    def db
      env['cloudflare.DB']
    end

    def h(text)
      Rack::Utils.escape_html(text.to_s)
    end

    # 入力をエスケープしたうえで改行だけ <br> に変換する簡易フォーマッタ
    def simple_format(text)
      h(text).gsub(/\r?\n/, '<br>')
    end

    def fmt_time(value)
      return '' unless value
      ts = value.to_i
      return '' if ts.zero?
      Time.at(ts).strftime('%Y-%m-%d %H:%M')
    end

    # posts が空のときだけ初期データ2件を流し込む。最初に DB が必要なルートで
    # 一度だけ呼べば、二度目以降は count(*) が 0 でなくなるので何もしない。
    def ensure_seed!
      rows = db.execute('SELECT count(*) AS c FROM posts')
      first = rows && rows.first
      count = first && (first['c'] || first[:c])
      return if count && count.to_i.positive?

      now = Time.now.to_i
      db.execute_insert(
        'INSERT INTO posts (title, body, created_at) VALUES (?, ?, ?)',
        ['Hello homura', "homura で書く初めての記事です。\n改行もそのまま表示されます。", now]
      )
      db.execute_insert(
        'INSERT INTO posts (title, body, created_at) VALUES (?, ?, ?)',
        ['Cloudflare Workers + Sinatra最高だね', "Workers の上で Sinatra が動くのは便利。\nD1 に永続化された小さなブログを試しています。", now]
      )
    end
  end

  get '/' do
    ensure_seed!
    @posts = db.execute('SELECT id, title, body, created_at FROM posts ORDER BY id DESC')
    erb :posts_index
  end

  get '/posts/new' do
    erb :posts_new
  end

  get '/posts/:id' do
    id = params[:id].to_i
    rows = db.execute('SELECT id, title, body, created_at FROM posts WHERE id = ? LIMIT 1', [id])
    @post = rows && rows.first
    if @post
      erb :posts_show
    else
      status 404
      erb :posts_not_found
    end
  end

  post '/posts' do
    title = params[:title].to_s.strip
    body  = params[:body].to_s
    title = '(no title)' if title.empty?
    meta = db.execute_insert(
      'INSERT INTO posts (title, body, created_at) VALUES (?, ?, ?)',
      [title, body, Time.now.to_i]
    )
    redirect "/posts/#{meta['last_row_id']}"
  end

  post '/posts/:id/delete' do
    id = params[:id].to_i
    db.execute('DELETE FROM posts WHERE id = ?', [id])
    redirect '/'
  end
end
