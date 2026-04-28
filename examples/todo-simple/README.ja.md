> 🇬🇧 English version: [README.md](README.md)

# todo-simple

> homura の最小サンプル。**Ruby ファイル 1 枚**で構成され、
> `Sinatra::Base` のサブクラスも `views/` ディレクトリも D1 も
> マイグレーションも持たない。クラシックスタイルのトップレベル DSL に、
> ルート直下に書いた heredoc の HTML が並ぶだけだ。

## このサンプルが示すもの

「homura に必要なものはこれだけで足りる」を見せたいときに丸ごとコピーするのに向いたサンプルである。
[`todo/`](../todo/) と比較して、以下を取り除いている。

| | `todo/` | `todo-simple/` |
|---|---|---|
| コードの形 | `class App < Sinatra::Base`（モジュラー） | クラシックなトップレベル DSL |
| コード分割 | `app/app.rb` + `views/*.erb` | プロジェクトルートの `app.rb` 一枚 |
| 永続化 | Cloudflare D1 | Ruby array（インメモリ） |
| マイグレーション | あり | なし |
| テンプレート | プリコンパイル済み ERB | インラインの Ruby heredoc |
| `wrangler.toml` のバインディング | `[[d1_databases]]` | なし |
| リポジトリ内のファイル数 | 約 10 | 6 |

それ以外は Puma で動かすときと同じ Sinatra そのものだ。

```ruby
require 'sinatra/cloudflare_workers'
require 'sinatra'

TODOS = []
NEXT_ID = [1]

get '/' do
  page <<~HTML
    <h1>todo-simple</h1>
    ...
    #{todos_html}
  HTML
end

post '/todos' do
  TODOS << { id: NEXT_ID[0], title: params[:title], done: false }
  NEXT_ID[0] += 1
  redirect '/'
end
# ...

run Sinatra::Application
```

ルートはトップレベル Sinatra の `main` デリゲータ上にそのまま登録される。
素の Sinatra README で目にするのと完全に同じ形だ。
データはトップレベルの `TODOS` array に置かれる。これはつまり、
**Worker isolate のライフタイムがそのままデータのライフタイム**になる、ということだ。
`wrangler dev` を再起動すれば todo は消える。これが「セットアップなし」の代償である。

## ファイル構成

```
todo-simple/
├── Gemfile           # opal-homura, homura-runtime, sinatra-homura — それだけ
├── Rakefile          # build / dev / deploy
├── config.ru         # require_relative 'app'
├── wrangler.toml     # main = "worker.entrypoint.mjs"、バインディングなし
├── package.json      # devDep: wrangler
├── app.rb            # ← すべてはここで起きる
└── public/robots.txt
```

`app/` サブディレクトリも `views/` サブディレクトリも `db/` サブディレクトリも存在しない。

## 動かし方

```bash
cd examples/todo-simple
bundle install
npm install

bundle exec rake build
bundle exec rake dev
# → http://todo-simple.localhost:1355/
```

curl で試す。

```bash
curl -sS -i http://todo-simple.localhost:1355/
curl -sS -i -X POST http://todo-simple.localhost:1355/todos -d 'title=Buy milk'
curl -sS    http://todo-simple.localhost:1355/
curl -sS -i -X POST http://todo-simple.localhost:1355/todos/1/toggle
curl -sS -i -X POST http://todo-simple.localhost:1355/todos/1/delete
```

## デプロイ

```bash
bundle exec rake deploy
```

D1 のセットアップも secret も不要。`wrangler deploy` を打てば終わりだ。

## このレイアウトを選ぶべきでないとき

以下のいずれかが必要になった瞬間に、代わりに
[`todo/`](../todo/) や [`todo-orm/`](../todo-orm/) をコピーすること。

- Worker の再起動を越えて生き残るデータが必要 → **D1** を使う。
- HTML が約 30 行を超える → **`views/*.erb`** を使い、マークアップの変更が
  Ruby 文字列いじりにならないようにする。
- 1 ファイルにルートが数本以上ある → `app/app.rb` と `routes/` ディレクトリに分割する。

`todo-simple` は、小さなアプリにおいて homura がそれらのいずれも *強制しない* ことを示すために存在している。
