# Homurabi 厳格計画書 (PLAN.md)

**作成日**: 2026-04-15
**ステータス**: ドラフト（マスター承認待ち）
**レビュアー**: マスター（kazuph） + GPT-5.4 (Codex)

---

## 0. この計画書の絶対原則 ⚠️ 最重要

> **マスターからの直接指示（原文ママ）**:
> 「このプランは動くことが目的ではなく、できる限り、mRuby ではなく、Ruby と Sinatra を使った Opal 基盤のプログラムを Cloudflare Workers で動かすことを目的としているので、まずフォールバック案を全て潰す必要があります。
>
> どういうことかというと、うまくいかないときに諦める。諦めて、例えば、Sinatra Compatible DSL にするみたいな、本来の目的を見失うような動きを一切認めないという計画書にしてください。つまり、計画にない代替案を使いまくって最終的なゴールに行くのではなく、今回は手段が目的なので、目的のために手段を変えないでください。」

### 0.1 不変原則（INVIOLABLE PRINCIPLES）
1. **手段が目的である**。「動くこと」ではなく「**Real Ruby + Real Sinatra + Opal 基盤 + Cloudflare Workers**」という構成を実現することそのものがゴール。
2. **諦める = 失敗**。技術的困難に直面した場合の正しい対応は「諦めて代替手段に逃げる」ではなく「**問題を分解して直す**」または「**マスターに状況を報告して判断を仰ぐ**」のいずれかのみ。
3. **計画にない代替案の独断採用は即時リジェクト**。一行たりとも本計画書に書かれていない代替手段を実装したら、その時点で**成果物全体がゴミ**として扱われる。
4. **手段を変えない**。目的のために手段を変えてはならない。手段こそが目的だから。

### 0.2 レビュー体制
- 各 Phase 完了時に **マスター + GPT-5.4 (Codex)** がレビューを実施
- レビューでは「**計画書通りに進んでいるか**」を最優先で確認
- ちょっとでも計画から逸脱して進行していた場合 → **即時リジェクト**、その Phase の成果物は**ゴミとして破棄**
- 逸脱が発覚したら Phase をやり直す。ショートカット禁止。

---

## 1. 目的（GOAL）

**Cloudflare Workers 上で、Real CRuby 構文の Ruby ソースコードを Opal でコンパイルした成果物として動かし、その上に janbiedermann がパッチした実物の Sinatra（フォーク版）を載せて、HTTPリクエストを Sinatra DSL でハンドリングできる状態を作る**。

### 1.1 ゴール状態の定義（Definition of Done）
以下が全て満たされた時のみ「達成」とする：
- [ ] **`kazuph/homurabi`** という新規 GitHub リポジトリが作成されている（homura とは別リポ）
- [ ] `app.rb` に Real Ruby 構文で Sinatra DSL を書ける（`require 'sinatra'`、`get '/' do ... end` など）
- [ ] その `app.rb` を Opal でコンパイルした JS が Cloudflare Workers のバンドルに含まれる
- [ ] 使われる Sinatra は **janbiedermann/sinatra** フォーク（または upstream に取り込まれた未来版）の**実物**
- [ ] `wrangler dev` で起動し、`curl localhost:8787/` で Sinatra のレスポンスが返る
- [ ] `wrangler deploy` で Cloudflare Workers 本番環境にデプロイでき、本番URLでも同様に動く
- [ ] **D1 / KV / R2** バインディングを Sinatra ルートから**全て**利用できる（`env.DB` / `env.KV` / `env.BUCKET` を Opal の Native module 経由で呼ぶ）

### 1.2 ゴールの中の不変要素（変更不可）
| 要素 | 固定値 | 変更可否 |
|---|---|---|
| 言語 | **Ruby（CRuby構文準拠）** | ❌ 不変 |
| Web フレームワーク | **Sinatra（janbiedermann/sinatra フォーク）** | ❌ 不変 |
| Ruby 実行基盤 | **Opal（Ruby→JS コンパイラ）** | ❌ 不変 |
| 実行環境 | **Cloudflare Workers（V8 isolate）** | ❌ 不変 |
| 実行モデル | **ESM Module Worker** | ❌ 不変 |
| リポジトリ | **`kazuph/homurabi`（新規リポジトリ）** | ❌ 不変 |
| 必須CFサービス | **D1 / KV / R2 が Sinatra ルートから呼べること** | ❌ 不変 |

**マスター指示（2026-04-15 追記）**:
- 本プロジェクトは **`kazuph/homura` の派生ブランチではなく、`kazuph/homurabi` という完全に新しい GitHub リポジトリ** として作成する。homura（mruby版）と homurabi（Opal版）は別プロダクトとして共存させる。
- D1 だけでなく **KV と R2 も Sinatra ルートから呼べること** をゴール条件に含める。Phase 3 の達成基準に追加。

---

## 2. 禁止事項（FORBIDDEN FALLBACKS）

以下は**全て禁止**。これらを採用したら計画違反として即時リジェクト：

### 2.1 言語/基盤の変更禁止
- ❌ **mruby に戻る**（Homura に帰るのは禁止。本プロジェクトは Homurabi）
- ❌ **ruby.wasm を使う**（CRuby/wasm32-wasi）
- ❌ **TruffleRuby / JRuby / Rubinius** などの代替実装を使う
- ❌ **Ruby を諦めて他言語にする**（Crystal、Elixir、JS、Python、TypeScript すべて禁止）

### 2.2 フレームワークの変更禁止
- ❌ **Sinatra-compatible DSL を自作する**（「Sinatraっぽい」ものを作るのは禁止）
- ❌ **Hono風の DSL を Ruby で書く**（Homura でやってる路線は禁止）
- ❌ **Roda / Hanami / Rails / その他 Ruby Web FW** に乗り換える
- ❌ **素の Rack ハンドラだけで済ませる**（Sinatra なしで Rack だけで終わらせるのは禁止）
- ❌ **Sinatra の一部機能だけ実装した薄いラッパー**で代用する

### 2.3 実行環境の変更禁止
- ❌ **Cloudflare Containers に逃げる**（Workers が無理だから Containers にする、は禁止）
- ❌ **Fly.io / Render / Heroku / Vercel** など別 PaaS に逃げる
- ❌ **Node.js サーバーとして動かす**（janbiedermann/up が動くからといって Node.js 化するのは禁止）
- ❌ **Service Worker / Browser** で動かして「動いた」と言うのは禁止

### 2.4 「動いたフリ」禁止
- ❌ **モック/スタブで Sinatra のレスポンスをでっち上げる**
- ❌ **Sinatra のコードを呼ばずにルーティングだけ自作で実装**
- ❌ **`require 'sinatra'` を読み替えて自作モジュールに置換**
- ❌ **テストを書かずに「動いた」と報告する**

### 2.5 計画外の脱出禁止
- ❌ **Phase の途中で「これは無理だから次に進もう」と独断で判断**
- ❌ **マスターに報告せずに代替案を採用**
- ❌ **「今はこれでいい、後で直す」とコメントを残して進行**

---

## 3. フォールバック禁止条項（ESCAPE PROHIBITION CLAUSE）

### 3.1 困難に直面したときの正しい行動
Phase を進める中で「これは無理かも」と思った瞬間、取れる行動は**以下の3つだけ**：

1. **問題を分解して根本原因を特定し、その根本を直す**
   - 例: 「Opal で `Mutex` が動かない」→ Opal の Mutex 実装を読んで、足りない部分にPRを送る or vendoring してパッチを当てる
2. **マスターに即時報告して判断を仰ぐ**
   - 「Phase X で〇〇が原因で詰まりました。打てる手は A/B/C です。どうしますか？」と聞く
3. **計画書を更新する提案をマスターに出す**
   - 計画書の変更は**マスターの明示承認**がない限り無効

**禁止される行動**:
- ❌ 独断で代替実装に切り替える
- ❌ 「とりあえず動くもの」を作って後回しにする
- ❌ Sinatra をやめて DSL を自作する
- ❌ Opal をやめて他のRuby実装に切り替える

### 3.2 計画違反の判定
以下のどれか一つでも該当したら、**その Phase の成果物は全てゴミとして破棄**される：
- 計画書に書かれていない技術スタックの導入
- 禁止事項リスト（§2）に該当する行為
- マスター/GPT-5.4 のレビュー前に commit/push した
- 「動かないから諦めた」が成果物に含まれる
- TODO/FIXME コメントで「Sinatra を後で本物に置き換える」的な逃げ道を残した

---

## 4. Phase 計画

各 Phase は**独立した Go/No-Go ゲート**を持つ。Go 判定は**マスターの明示承認**が必須。No-Go の場合は §3.1 のいずれかの行動を取る（諦めるのは禁止）。

### Phase 0: 新規リポジトリ作成とベースライン確認
**目的**: `kazuph/homurabi` を新規リポジトリとして作成し、Opal の最小ビルドが Cloudflare Workers で動くかを確認

#### タスク
1. **`kazuph/homurabi` GitHub リポジトリを新規作成**（`gh repo create kazuph/homurabi --public --description "Real Ruby + Sinatra on Cloudflare Workers via Opal"`）
2. ローカルクローン: `~/src/github.com/kazuph/homurabi`
3. **本計画書 `PLAN.md` を新リポジトリの `.artifacts/homurabi/PLAN.md` にコピー**（homura リポの方は seed として残す）
4. `kazuph/homurabi` 内で `git wt feature/phase0-baseline` を切って Phase 0 作業ブランチを作る
5. Ruby 環境準備: `rbenv` で Ruby 3.3+ をインストール、`bundle init`
6. `Gemfile` に `gem 'opal', '~> 1.8'` を追加して `bundle install`
7. `puts "hello"` だけ書いた `hello.rb` を `opal -c -e 'puts "hello"' --esm` でコンパイルしてサイズ実測
8. 出力された `.mjs` を Node.js で実行して動作確認
9. **同じ ESM ファイルを Cloudflare Workers の最小 Worker で `import` してデプロイ**してエッジで `puts` 相当が動くことを確認

#### Go 判定基準（全て満たす必要あり）
- [ ] `kazuph/homurabi` リポジトリが GitHub 上に存在する
- [ ] そのリポジトリに本計画書 `PLAN.md` がコピーされている
- [ ] Opal が ESM 形式で出力できた
- [ ] 出力 ESM が Cloudflare Workers にデプロイできた
- [ ] CF Workers 上で `puts` 相当（`console.log` への橋渡し）が実行された
- [ ] バンドルサイズが Workers の上限（**圧縮後 10MB**）以内に収まっている

#### No-Go 時の禁止行動
- ❌ 「サイズが大きいから minify を強化して諦める」→ 諦める前に Opal の `--no-stdlib` などのオプションを徹底的に試す
- ❌ 「Workers で動かないから Pages にする」→ Workers 必須
- ❌ 「`homura` リポの中にディレクトリ切って済ます」→ 別リポ必須

---

### Phase 1: CF Workers 向け Opal ランタイムアダプタ作成
**目的**: Opal の `quickjs.rb` / `deno.rb` と同等のアダプタを CF Workers 用に書く

#### タスク
1. `homurabi/lib/cloudflare_workers.rb` を新規作成（`stdlib/quickjs.rb` を参照しながら）
2. `addEventListener('fetch', ...)` ではなく **ESM Module Worker 形式**（`export default { fetch }`）に対応
3. CF Workers の `fetch(request, env, ctx)` ハンドラから Opal 側の Ruby 関数を呼べる橋を作る
4. Ruby 側で `$$` 経由で `Request` / `Response` / `Headers` を扱えることを確認
5. **Phase 0 の "hello" を Ruby で書いて、それが HTTP レスポンスとして返る** ことを確認

#### Go 判定基準
- [ ] `homurabi/lib/cloudflare_workers.rb` が存在する
- [ ] Ruby で書かれた `app.rb` が `Response.new("hello")` 相当を返せる
- [ ] `wrangler dev` で `curl localhost:8787/` が `hello` を返す
- [ ] 本番デプロイした Workers でも同じレスポンスが返る

#### No-Go 時の禁止行動
- ❌ 「Native module でうまくいかないから JS で書く」→ Ruby で書ききる
- ❌ 「ESM Module Worker が無理だから Service Worker 形式にする」→ ESM 必須

---

### Phase 2: janbiedermann/sinatra を実物として組み込む
**目的**: フォーク版 Sinatra を実物のままバンドルして `require 'sinatra'` できる状態にする

#### タスク
1. `janbiedermann/sinatra` を git submodule または vendoring で取り込む（**fork のコードは1行も書き換えない**。書き換えが必要なら upstream に PR を出す方針で進める）
2. Sinatra の依存（patched `rack`, `mustermann`, `rack-protection`, `rack-session`, `tilt`）も同様に janbiedermann フォークから取り込む
3. Opal の builder で `require 'sinatra'` を解決させる
4. ビルドエラーが出たら **Opal 側 or Sinatra 側のどちらが原因か特定**し、§3.1 の正しい行動を取る
5. `app.rb` で `require 'sinatra'; get('/') { 'hello from sinatra' }` を書いて、Workers 上でレスポンスを返させる

#### Go 判定基準
- [ ] `app.rb` のソース上に `require 'sinatra'` と `get '/' do ... end` が**そのまま**書かれている
- [ ] そのコードがコンパイルされて Workers にデプロイされている
- [ ] `curl` で Sinatra のレスポンスが返る
- [ ] **Sinatra のコードが実際に評価されている証拠**を残す（Sinatra 内部のログを仕込む or stack trace でフレームを確認）

#### No-Go 時の禁止行動
- ❌ 「Sinatra の特定機能が動かないから自作 DSL に置換」→ 絶対禁止
- ❌ 「`require 'sinatra'` を `require 'my_sinatra_like'` に書き換える」→ 絶対禁止
- ❌ 「Sinatra の代わりに Rack ハンドラ直書きで済ます」→ 絶対禁止

---

### Phase 3: D1 / KV / R2 バインディングを Sinatra ルートから呼ぶ
**目的**: 実際の CF サービス（D1 / KV / R2 すべて）と Sinatra を接続する

#### タスク
1. `wrangler.toml` に **D1 / KV / R2 すべて** を定義
2. Opal の Native module 経由で以下を Sinatra ルート内から呼ぶ：
   - **D1**: `env.DB.prepare(...).all()` で SELECT
   - **KV**: `env.KV.get(key)` / `env.KV.put(key, value)`
   - **R2**: `env.BUCKET.get(key)` / `env.BUCKET.put(key, body)`
3. 各バインディングを使う Sinatra ルートを実装：
   - `get '/d1/users'` → D1 から取得
   - `get '/kv/:key'` / `post '/kv/:key'` → KV CRUD
   - `get '/r2/:key'` / `put '/r2/:key'` → R2 CRUD
4. レスポンスとして各サービスから取得した値を返す

#### Go 判定基準（全て満たす必要あり）
- [ ] Sinatra の各ルート内で `env.DB` / `env.KV` / `env.BUCKET` を**全て**呼んでいる
- [ ] 実際に D1 から取得した値がレスポンスに含まれる
- [ ] 実際に KV から取得/保存した値がレスポンスに含まれる
- [ ] 実際に R2 から取得/保存したオブジェクトがレスポンスに含まれる
- [ ] 全てのテスト（D1/KV/R2 各CRUD）が通る

#### No-Go 時の禁止行動
- ❌ 「D1 だけ動けば KV/R2 は後回し」→ 3つ全部必須
- ❌ 「Native module で呼べないから JS 側で wrap して Ruby から呼ぶ」→ Opal の Native module で完結させる

---

### Phase 4: 動作証跡の収集とレビュー提出
**目的**: artifact-proof スキルで証跡を残し、本物の Sinatra が動いていることを証明

#### タスク
1. `wrangler dev` 起動中の `curl` ログを取る
2. ブラウザ（webapp-testing スキル）で動作確認スクショ
3. Sinatra フレームに到達していることを証明するスタックトレース or デバッグログ
4. `wrangler deploy` 後の本番 URL での動作確認スクショ
5. `.artifacts/homurabi-poc/` に全証跡を集約
6. `REPORT.md` を artifact-proof スキルで作成
7. `/reviw-plugin:done` 実行
8. **マスター + GPT-5.4 によるレビュー** を foreground で受ける

#### Go 判定基準
- [ ] 全証跡が `.artifacts/` に揃っている
- [ ] マスターの明示承認が取れた
- [ ] GPT-5.4 (Codex) のレビューも通った

---

## 5. レビュー条項（REVIEW CLAUSE）

### 5.1 各 Phase レビュー
- 各 Phase 完了時に **必ず** マスター + GPT-5.4 (Codex) のダブルレビューを受ける
- レビューでは「**この Phase の成果物が本計画書通りであるか**」を最優先で確認
- 確認ポイント:
  1. 禁止事項（§2）に触れていないか
  2. フォールバック禁止条項（§3）に違反していないか
  3. Go 判定基準を**全て**満たしているか
  4. 計画書に書かれていない技術スタックを導入していないか
  5. TODO/FIXME で逃げ道を残していないか

### 5.2 リジェクト条件
ちょっとでも計画から逸脱して進行してしまった場合、**その時点で成果物全体がゴミ**として扱われる。具体的には：
- 該当 Phase をやり直す（前の状態に戻す）
- 逸脱の原因を分析し、計画書を更新する提案をマスターに出す
- マスター承認後に再着手

### 5.3 GPT-5.4 (Codex) レビューの呼び出し
- 各 Phase 完了時に `/codex review --base main` を実行
- Codex には本計画書を読ませて「**計画通りか**」を判定させる
- Codex が計画違反を指摘したら、マスターのレビューより前に修正する

---

## 6. リスクと事前合意事項

### 6.1 既知のリスク
| リスク | 起こったときの正しい対応（§3.1 のいずれか） |
|---|---|
| Opal バンドルが Workers の 10MB を超える | stdlib の選別、tree-shaking、minify 強化を**全て**試す。それでもダメならマスターに報告 |
| Sinatra のメタプロが Opal で動かない | Opal 側にPRを出すか、フォークしてパッチを当てる（**Sinatra-like DSL に置換するのは禁止**） |
| `Mutex` / `Thread` / `IO` が CF Workers で動かない | Opal の `await` / Promise stdlib を使って同期セマンティクスを再現する |
| `require 'sinatra'` の依存解決が複雑 | janbiedermann の依存ツリーをそのままベンダリングする |
| パフォーマンスが極端に悪い | 計画段階では問題視しない。**動くこと**より**手段の正しさ**が優先 |

### 6.2 マスターに事前合意してもらいたいこと
- [ ] §0 の絶対原則を読み、フォールバック禁止に同意した
- [ ] §2 の禁止事項リストに追加・削除がないか確認した
- [ ] §4 の Phase 数と粒度に同意した
- [ ] §5 のレビュー条項（マスター + GPT-5.4 ダブルレビュー）に同意した
- [ ] 「計画違反 = 即時リジェクト = ゴミ」というペナルティに同意した

---

## 7. 計画書の改訂ルール

- 本計画書は **マスターの明示承認なしに変更禁止**
- 変更が必要な場合は「**変更提案**」をマスターに出し、承認を得てから改訂する
- 改訂履歴はこのファイルの末尾に追記する

### 改訂履歴
- 2026-04-15: 初版作成（部長執筆、マスター承認待ち）
- 2026-04-15: マスターのAskUserQuestion回答を反映
  - §1.2 不変要素に **`kazuph/homurabi` 新規リポジトリ**と **D1/KV/R2 必須**を追加
  - §1.1 Definition of Done に新規リポジトリ条件と KV/R2 を追加
  - Phase 0 を「新規リポジトリ作成 + ベースライン確認」に書き換え
  - Phase 3 を D1 のみ → D1/KV/R2 全部に拡張

---

## 8. マスターへの確認事項

この計画書を読んで、以下を確認してください：

1. **目的の固定**: §1.2 の不変要素（Ruby/Sinatra/Opal/Workers/ESM）に過不足はないか？
2. **禁止事項**: §2 のリストに追加すべき禁止事項はあるか？特に「これだけは絶対やるな」というものがあれば追記したい
3. **Phase 粒度**: §4 の Phase 0〜4 の粒度は適切か？ もっと細かく切るべきか？
4. **レビュー方法**: §5 の GPT-5.4 レビュー方法は `/codex review --base main` でいいか？ 別の呼び出し方を希望する？
5. **着手タイミング**: この計画書を承認したら、Phase 0 から worktree 作成して着手していいか？

**マスターの返答待ち。承認なしに Phase 0 には着手しない。**
