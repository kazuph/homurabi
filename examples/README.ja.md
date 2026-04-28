> 🇬🇧 English version: [README.md](README.md)

# Examples

公開済みの [homura](../) gem 群の上に構築された、完全に動作する 6 つのアプリケーション。
各 example は独立したプロジェクトであり、`Gemfile` は monorepo への `path:` 参照を使わず、4 つの gem を RubyGems から直接ピン留めしている。そのため、どの example もこのディレクトリからコピーアウトしてそのまま単独で出荷できる。

これらのアプリは最新の gem リリースの裏にある回帰テスト用フィクスチャでもある。4 つの gem が吸収する Workers/Opal の差異それぞれについて、標準的な Sinatra / Sequel / ERB のイディオムが上流ドキュメント通りに動くことを証明する example が少なくとも一つ存在する。

## 収録内容

| Example | スタック | 特徴 |
|---|---|---|
| [`todo/`](todo/) | Sinatra + D1 (ORM なし) | 最小の D1 CRUD。`env['cloudflare.DB']` と `Cloudflare::D1Database#execute` / `execute_insert` API を直接利用 — Sequel なし。 |
| [`todo-orm/`](todo-orm/) | Sinatra + D1 + Sequel | 同じ TODO ドメインを `sequel-d1` 経由で実装。Datasets、`.first`、`.update(... Sequel.lit ...)`、マイグレーション DSL → wrangler 対応 SQL。 |
| [`auth-otp/`](auth-otp/) | Sinatra + D1 + mailpit + Playwright | 開発時の [mailpit](https://mailpit.axllent.org/) シンクを利用したメール OTP ログイン。HMAC で署名されたセッション cookie。エンドツーエンド検証用に `rake e2e` (Net::HTTP) と `rake e2e:headed` (実際の Chromium) を提供。 |
| [`blog/`](blog/) | Sinatra + D1 (ORM なし) | 一覧 / 詳細 / 新規作成 / 適切な 404 / 削除。非同期ルートパイプラインの下でも `status 404; erb :posts_not_found` が 200 ではなく 404 を返すことを示す。 |
| [`inertia-todo/`](inertia-todo/) | Sinatra + Inertia.js + Vue 3 | サーバーレンダリングされる Inertia ページオブジェクト、`X-Inertia` コンテンツネゴシエーション、JSON props。クライアント JS は `public/assets/inertia-app.js` に存在。 |
| [`hotwire-todo/`](hotwire-todo/) | Sinatra + Turbo Streams + Stimulus | `Accept: text/vnd.turbo-stream.html` ネゴシエーション越しのサーバーレンダリング turbo-stream パーシャル。クライアント JS はオートフォーカス用の小さな Stimulus コントローラーのみ。 |

このフォルダに同居する `examples/minimal-sinatra*` ディレクトリは、古い monorepo 専用のスモークテストである。`path:` 参照を使っており、新規プロジェクトのテンプレートには適さない。

## example の実行方法

前提条件: Ruby 3.4+、Node 20+、[`portless`](https://github.com/vercel-labs/portless)（任意。安定した `*.localhost` URL の利用と、複数の example を同時起動した際のポート衝突回避のため）。

```bash
cd examples/<name>
bundle install
npm install
# D1 を使う example の場合:
bundle exec rake db:migrate:local

bundle exec rake build      # opal compile + ERB precompile + asset embed
bundle exec rake dev        # wrangler dev (portless が利用可能なら経由)
```

すべての example は同じ Rake インターフェイスを公開している。

| Task | 内容 |
|---|---|
| `rake build` | Workers ビルド一式（Opal コンパイル、ERB プリコンパイル、アセット埋め込み、auto-await 書き換え）を実行する。出力: `build/worker.entrypoint.mjs`。 |
| `rake dev` | `wrangler dev --local` を `portless` 配下で起動し、アプリを `http://<example-name>.localhost:1355/` でアクセス可能にする。 |
| `rake deploy` | 自身の Cloudflare アカウントへ `wrangler deploy` する（事前に `wrangler.toml` をセットアップしておくこと）。 |
| `rake db:migrate:compile` *(D1 の example)* | `homura db:migrate:compile` を実行し、`db/migrate/` 配下の Sequel マイグレーション DSL を wrangler 対応 SQL に変換する。 |
| `rake db:migrate:local` *(D1 の example)* | コンパイル後に `wrangler d1 migrations apply <db> --local` を実行する。 |
| `rake db:migrate:remote` *(D1 の example)* | コンパイル後に `wrangler d1 migrations apply <db> --remote` を実行する。 |

`auth-otp` には独自の追加タスクが 2 種類ある。メールシンク用の `rake mailpit:start` / `rake mailpit:stop` と、エンドツーエンドフロー用の `rake e2e` / `rake e2e:headed` である。詳細は [`auth-otp/README.md`](auth-otp/README.md) を参照。

## 共通の規約

6 つの example はすべて同じ形を踏襲しており、互いに同じように読める構造になっている。

```
example/
├── Gemfile              # 公開 gem のみ — opal-homura, homura-runtime,
│                        # sinatra-homura, (任意で sequel-d1)
├── Rakefile             # build / dev / deploy / db:migrate:*
├── config.ru            # require_relative 'app/app'; run App
├── package.json         # devDep: wrangler
├── wrangler.toml        # main = "build/worker.entrypoint.mjs"; bindings はここ
├── app/
│   └── app.rb           # Sinatra::Base のサブクラス — ルート定義
├── views/               # *.erb (ビルド時にプリコンパイル)
├── public/              # 静的アセット (ビルド時に埋め込み)
└── db/migrate/          # *.rb Sequel マイグレーション + コンパイル済み *.sql (D1 のみ)
```

`bundle exec rake build` を走らせると、生成される `worker.entrypoint.mjs`
とその `cf-runtime/` グルーは別ディレクトリ `build/` に置かれる。`build/`
は gitignore 対象なので、どちらもソース管理には現れない。

`app/` と `views/` 配下の Ruby は、CRuby Sinatra で書くのとまったく同じ Ruby そのものだ。ビルドパイプラインが `__await__` 呼び出しを書き換え、ERB をプリコンパイルし、`public/` をビルド時に埋め込むので、ランタイムは Workers にファイルシステムが存在しないことを意識しなくて済む。

## なぜ portless か

6 つの wrangler dev プロセスを同時に走らせるということは、6 つの TCP ポートを覚えておく必要があるということだ。[`portless`](https://github.com/vercel-labs/portless) はそれらを安定したサブドメイン (`http://todo.localhost:1355/`、`http://blog.localhost:1355/`、…) の下にプロキシしてくれるので、wrangler がたまたまどのポートにバインドしようと、cookie もリンクもスクリーンショットもすべて有効なまま保たれる。各 example の `Rakefile` は portless がインストールされていればそれ経由で wrangler を起動する。インストールされていない場合は、`bundle exec rake dev` を素の `npx wrangler dev --local --port 8787` 呼び出しに置き換えればよい。

## これらの example をいじる

各 example は独自の `Gemfile.lock` を保持しているので、新規に `bundle install` すれば、その example が最後に検証された時点の gem バージョンに正確にピン留めされる。Ruby コードを変更したあとは `bundle exec rake build` で `build/worker.entrypoint.mjs` を再ビルドすれば、`wrangler dev` がファイル変更でホットリロードする。

表示された URL でブラウザを開き、アプリを操作し、実際に何が永続化されたかを確認したければ `.wrangler/state/v3/d1/` 配下のローカル D1 ファイルを覗いてみるとよい。
