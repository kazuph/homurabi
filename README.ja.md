> 🇬🇧 English version: [README.md](README.md)

<p align="center">
  <img src="site/public/homura-chan.png" alt="homura mascot" width="200">
</p>

# homura

**Cloudflare Workers で本物の Ruby アプリを動かすプラットフォーム。**

稼働中のサイト: <https://homura.kazu-san.workers.dev>

```ruby
# app.rb — そう、これは本当にただの Sinatra だ。
require 'sinatra'
require 'sequel'

get '/' do
  'Hello from Ruby, running on Cloudflare Workers.'
end

get '/users' do
  db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
  content_type :json
  db[:users].order(:id).all.to_json
end
```

```toml
# wrangler.toml — Cloudflare がそのまま期待する形。
name = "myapp"
main = "build/worker.entrypoint.mjs"
compatibility_date = "2026-04-27"
compatibility_flags = ["nodejs_compat"]
```

シムも、トランスパイルされた Sinatra もどきも存在しない。`require 'sinatra'`
は canonical な Sinatra ポートをロードする。`redirect '/'` は Sinatra 純正の
`HaltResponse` を raise する。`erb :index, locals: { user: u }` もドキュメント
通りに locals を解決する。modular スタイル（`class App < Sinatra::Base` +
`config.ru` + `run App`）もそのまま動く — 例として
[`examples/todo/`](examples/todo/) と canonical な
[`site/`](site/)（homura.kazu-san.workers.dev）を参照。
このパイプライン全体は、Ruby ユーザーが Ruby を書き続けたまま Cloudflare の
エッジに届けられるようにするためだけに存在する。

---

## なぜ homura か

Cloudflare Workers は Ruby VM を動かさない。動くのは V8 上の JavaScript
で、ファイルシステムも、文字列からの `eval` も、ネイティブ拡張もない。
標準的な Ruby スタック — Sinatra、Sequel、`SecureRandom`、ERB — はその
すべてを当然のように要求する。

homura はそのギャップを埋めるための糊だ。

- **本物の Sinatra DSL** — `get`、`post`、`before`、`after`、`helpers`、
  `halt`、`redirect`、`locals:` とレイアウト付きの `erb`、`Sinatra::Base`
  の継承。すべて upstream のドキュメント通りに動く。
- **エッジで動く SQL** — `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`
  が Cloudflare D1 に対してそのまま動く。マイグレーションは Sequel DSL
  で書き、wrangler 互換の SQL にコンパイルされる。ORM を飛ばして
  `Cloudflare::D1Database` ラッパーを直接使うこともできる。
- **すべての binding** — D1、KV、R2、Workers AI、Queues、Scheduled、
  Durable Objects、Vectorize。これらは普通の Ruby オブジェクトとして
  `request.env['cloudflare.<NAME>']` に現れる。
- **普通の流通形態** — RubyGems 上の 4 つの gem。`path:` 参照も、
  submodule も、homura 本体の clone も不要。
- **儀式なしの非同期** — ビルド工程が、Workers の要求する `__await__`
  呼び出しを「CRuby で書くなら当然こう書くだろう」という同期に見える
  ソースに書き換える。`db.execute(...)` は coroutine ではなく
  sqlite3-ruby のように読める。

素の Sinatra-on-Workers のイディオムが Ruby 開発者の期待通りに動かない
場合、それはスタックの癖ではなく homura のバグだ。
[examples/](examples/) ディレクトリがその契約を担う。

---

## 仕組み

```
                         CRuby (ビルドホスト)               Cloudflare Workers (V8)
                ┌────────────────────────────────┐        ┌──────────────────────────┐
 あなたの Ruby ─►│  bundle exec rake build         │ ─────► │   build/worker.entrypoint.mjs  │
 あなたの View ─►│   ├─ Opal compile (Ruby → JS)   │        │   (wrangler が読み込む)  │
 マイグレーション►│   ├─ ERB precompile             │        │   ├─ homura runtime      │
                │   ├─ public/ アセット埋め込み   │        │   ├─ コンパイル済みアプリ│
                │   └─ auto-await 変換             │        │   └─ binding shim        │
                └────────────────────────────────┘        └──────────────────────────┘
```

仕事を担うのは 4 つの gem。

| Gem | 責務 |
|---|---|
| [`opal-homura`](https://rubygems.org/gems/opal-homura) | パッチ適用済み Opal コンパイラ。Ruby を V8 が走らせる JavaScript に変換する。`require: 'opal'` のままで使う。 |
| [`homura-runtime`](https://rubygems.org/gems/homura-runtime) | Worker のエントリポイント、Rack アダプタ、Cloudflare binding ラッパー（D1/KV/R2/AI/Queue）、ビルドパイプライン（`homura build`）。 |
| [`sinatra-homura`](https://rubygems.org/gems/sinatra-homura) | Sinatra ポート ＋ Opal 互換パッチ、scaffolder（`homura new`）、JWT / Scheduled / Queue ヘルパー、ERB プリコンパイラ。 |
| [`sequel-d1`](https://rubygems.org/gems/sequel-d1) | Cloudflare D1 用 Sequel アダプタ、マイグレーションコンパイラ（`homura db:migrate:*`）。 |

ビルドの成果物は **単一の `build/worker.entrypoint.mjs`** と、それに埋め込まれた
アセットバンドル。`wrangler deploy` がそのファイルをそのままエッジに
送り出す。

---

## クイックスタート: 新規プロジェクト

前提: Ruby 3.4+、Node 20+、`wrangler`（または `npx wrangler`）。

```bash
# scaffolder をインストール。
gem install sinatra-homura

# プロジェクトを生成（D1 + Sequel が欲しければ --with-db を付ける）。
homura new myapp
cd myapp

# 依存関係をインストール。
bundle install
npm install

# Worker バンドルをビルド。
bundle exec rake build

# wrangler dev をローカルで起動。
bundle exec rake dev
# → http://127.0.0.1:8787
```

`homura new --with-db myapp` を使うと、`db/migrate/` 配下に Sequel の
マイグレーションが追加され、`wrangler.toml` に D1 binding が宣言され、
`db:migrate:compile`、`db:migrate:local`、`db:migrate:remote` の Rake
タスクが追加される。ローカル開発のサイクルは次の通り。

```bash
bundle exec rake db:migrate:local   # ローカル D1 (sqlite shim) にマイグレーション適用
bundle exec rake build              # Ruby を編集したら再ビルド
bundle exec rake dev                # wrangler dev、再ビルド時にホットリロード
```

本番デプロイ:

```bash
npx wrangler d1 create myapp                       # 初回のみ
# 生成された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote                 # リモート D1 に適用
bundle exec rake deploy                            # wrangler deploy
```

---

## 既存プロジェクトへの homura 導入

すでに Ruby があり、それを Workers に届けたい場合:

1. **4 つの gem を `Gemfile` に固定する**:

   ```ruby
   source 'https://rubygems.org'
   ruby '>= 3.4.0'

   gem 'rake'
   gem 'opal-homura',    '= 1.8.3.rc1.5', require: 'opal'
   gem 'homura-runtime', '~> 0.3'
   gem 'sinatra-homura', '~> 0.3'
   gem 'sequel-d1',      '~> 0.3'   # D1 / Sequel を使う場合のみ
   ```

2. **Sinatra アプリは書いたままでよい。** classic スタイル
   （`require 'sinatra'` + トップレベルの `get '/' do ... end`）も
   modular スタイル（`require 'sinatra/base'` + `class App < Sinatra::Base`
   + `config.ru` で `run App`）もどちらも upstream のドキュメント通りに
   動く。`require` を Cloudflare 専用のものに差し替える必要は **ない** —
   sinatra-homura が標準の Sinatra エントリポイントの上で Workers ランタイム
   を自動的に配線する。

3. **`wrangler.toml` を追加** し、`main` を `build/worker.entrypoint.mjs` に
   向け、必要な binding（D1 / KV / R2 / AI / Queue）を宣言する。

4. **ビルドして起動**: `bundle exec rake build && bundle exec rake dev`。

既存の classic スタイル Sinatra アプリを移行する場合、最短経路は
`examples/classic-top-sinatra/` をコピーしてそこにルートをマージする
ことだ。modular スタイルなら、ORM なしの `examples/todo/` か、
Sequel + D1 を使う `examples/todo-orm/` から始めるとよい。

下の [Workers の落とし穴](#既知の落とし穴と対処場所) セクションには、
Workers ランタイムが CRuby との分岐を強いる数少ない場所がまとめて
ある。

---

## 例

[`examples/`](examples/) には 11 個の完全に動作するアプリがある。それぞれが
公開済みの gem だけに依存するスタンドアロンプロジェクトで、monorepo
への `path:` 参照は持たない。これらは最新の gem リリースの裏にある
リグレッションフィクスチャでもある。

| Example | Live | 何を示すか |
|---|---|---|
| [`sinatra`](examples/sinatra/) | <https://sinatra.kazu-san.workers.dev/> | classic Sinatra README そのまま — `require 'sinatra'` + `get '/frank-says'`。`app.rb` 1 ファイル、D1 なし、views なし。 |
| [`classic-top-sinatra`](examples/classic-top-sinatra/) | <https://classic-top-sinatra.kazu-san.workers.dev/> | `sinatra` と同じ形で `content_type :json` + JSON ルートを足し、classic トップレベル DSL を dogfood するもの。 |
| [`sinatra-with-db`](examples/sinatra-with-db/) | <https://sinatra-with-db.kazu-san.workers.dev/> | 最小の D1 付き Sinatra: `Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])`、ルート 1 個、マイグレーション 1 個。 |
| [`sinatra-with-email`](examples/sinatra-with-email/) | <https://sinatra-with-email.kazu-san.workers.dev/> | Phase 17.5 auto-await デモ — `SEND_EMAIL` Cloudflare Email バインディング越しの POST `/send`、ソース上に `.__await__` ゼロ。 |
| [`todo-simple`](examples/todo-simple/) | <https://todo-simple.kazu-san.workers.dev/> | **最小のステートフルサンプル。** `app.rb` 1 つ、`views/` なし、D1 なし — HTML は Ruby の heredoc で書く。「homura はどれだけ少なくて済むか」を示す。 |
| [`todo`](examples/todo/) | <https://todo.kazu-san.workers.dev/> | ORM なしの D1 ベース CRUD — `env['cloudflare.DB']` と `Cloudflare::D1Database` を直接使う。 |
| [`todo-orm`](examples/todo-orm/) | <https://todo-orm.kazu-san.workers.dev/> | 同じ TODO アプリを `sequel-d1` 経由で書いたもの。マイグレーション、データセットチェイン、`.first` / `.update`。 |
| [`auth-otp`](examples/auth-otp/) | <https://auth-otp.kazu-san.workers.dev/login> | メール OTP ログイン。開発時は [mailpit](https://mailpit.axllent.org/) で送信、HMAC 署名付きセッション cookie、`rake e2e:headed` でフルの headed Playwright E2E。 |
| [`blog`](examples/blog/) | <https://blog.kazu-san.workers.dev/> | 小さなブログ: 一覧 / 詳細 / 新規 / **適切な 404** / 削除。非同期ルートのステータス保持と `<%= h(post[:body]).gsub("\n", "<br>") %>` を示す。 |
| [`inertia-todo`](examples/inertia-todo/) | <https://inertia-todo.kazu-san.workers.dev/> | [Inertia.js](https://inertiajs.com) + Vue 3 による薄い SPA。Sinatra がページ props を提供する。クライアント JS は `public/assets/` 配下。 |
| [`hotwire-todo`](examples/hotwire-todo/) | <https://hotwire-todo.kazu-san.workers.dev/> | Turbo Streams（Accept ネゴシエーション越しのサーバーレンダリング partial）+ オートフォーカス用の小さな Stimulus コントローラー。 |

URL とアプリごとの機能メモを含むフルインデックスは
[`examples/README.md`](examples/README.md) を参照。

---

## 既知の落とし穴と対処場所

Workers ランタイムは CRuby との実際の差分をいくつか強いる。homura は
それぞれを gem 層で吸収するので、アプリケーションコードでは意識する
必要がない。

- **`String#<<` がない。** Opal の String は JS の string なので、変更で
  出力を組み立てるコード（`host = String.new; host << '...'`）は壊れる。
  `sinatra-homura` は `Sinatra::Helpers#uri` / `redirect` / `content_type`
  を `+` による連結で書き直しているので、`redirect to('/')` は
  Sinatra のドキュメント通りに動く。
- **`binding.eval` がない。** Workers は ERB がテンプレートレンダリングに
  使う `new Function(string)` をブロックする。`homura-runtime` は
  ビルド時に全ての `views/*.erb` を Ruby メソッドへプリコンパイルし、
  `erb :name` をそこへディスパッチする。`erb :_partial, locals: { t: t }`
  は template-locals スタック ＋ `Sinatra::Base#method_missing` 経由で
  裸の `t` を解決する。
- **ファイルシステムがない。** `public/` はビルド時にバンドルされ、
  homura が組み込む Rack ミドルウェア経由でメモリから配信される。
- **Opal 下では `String == Symbol`。** `Sequel::LiteralString` が Sequel
  の `case v when Symbol` 分岐に拾われ、バッククォート引用された
  識別子として吐かれていた。`sequel-d1` は `literal_append` の分岐
  順を入れ替え、`update(done: Sequel.lit('1 - done'))` が
  `literal_literal_string_append` に届くようにしている。
- **エッジでの非同期。** D1 / KV / fetch はすべて promise の形をしている。
  ビルドパイプラインは auto-await パスを実行し、登録済みの非同期
  メソッド（`db.execute`、`kv.get`、`Cloudflare::AI.run`、…）に対して
  `__await__` を挿入する。これによりルート本体は同期的な見た目の
  まま保てる。

「素直に動くべき」なのに動かないイディオムを見つけたら、それはこの
リストに載るべき項目だ。issue を立ててほしい。

---

## AI / エージェントサポート

homura はエージェントが発見可能なドキュメントを同梱しているので、
Claude / Copilot / Cursor が人間の介在なしに正しい gem を選び、
正規のインストール／ビルドフローを辿れる。

- **機械可読なサマリ**: [`/llms.txt`](site/public/llms.txt) — ライブでも
  <https://homura.kazu-san.workers.dev/llms.txt> で配信されている。
- **詳細ドキュメント**: <https://homura.kazu-san.workers.dev/docs>
  （このリポジトリの `docs/` からレンダリング可能）。
- **インストール可能なエージェント skill**:
  [`skills/homura-workers-gems/`](skills/homura-workers-gems/) —
  どの gem を選ぶべきか、最小の `homura new` フロー、頻出する
  Workers/Opal の落とし穴をエージェントに教えるパッケージ済み
  Claude / Copilot skill。

skill のインストール:

```bash
# GitHub Copilot（または `gh skill` を読むホスト全般）
gh skill install kazuph/homura homura-workers-gems --agent github-copilot --scope user

# Claude Code（プロジェクトスコープ推奨）
gh skill install kazuph/homura homura-workers-gems --agent claude-code --scope project

# npm ベースのインストーラ（Claude / Copilot にも使える）
npx skills add kazuph/homura --skill homura-workers-gems -a claude-code
```

---

## リポジトリ構成

```
gems/                 # 公開している 4 つの gem はここ
  homura-runtime/     # コアランタイム + ビルドパイプライン
  sinatra-homura/     # Sinatra ポート + Opal パッチ + scaffolder
  sequel-d1/          # Sequel D1 アダプタ + マイグレーションコンパイラ
  sinatra-inertia/    # Sinatra 向け Inertia.js v2 アダプタ
vendor/opal-gem/      # opal-homura（パッチ適用済み Opal フォーク）のソース
vendor/                 # Workers 向けに同梱した Sinatra / Rack / Sequel 等
examples/             # リリース済み gem を使うスタンドアロンサンプル群
site/                 # canonical な homura.kazu-san.workers.dev 本体
                      # （Sinatra アプリ、ERB ビュー、public/、wrangler.toml）
test/                 # gem 側のスモーク + Ruby テスト（`npm test`）
docs/                 # 詳細ドキュメント
skills/               # インストール可能なエージェント skill
```

`gems/*` ディレクトリと `vendor/opal-gem/` が出荷面（shipping surface）だ。
`site/` は gem の dogfooding 兼 end-to-end の動作確認場所で、gem コードと
同じリポジトリに同居しているので、ランタイム側の regression は出荷直後に
気付ける構成になっている。

---

## ライセンス

MIT。[`LICENSE`](LICENSE) を参照。
