# Phase 14 — posts + login + navi 整備 + 本番 migration 検証

- ブランチ: `feature/phase14-posts-login-navi` (push 済、PR 未作成)
- 直近 commits:
  - `3db6c0f` feat(phase14): posts table (Sequel migration), login flow, navi refresh
  - `a3565cd` perf(phase14): drop `helpers do` + before filter for startup CPU budget
- ベース: `main` @ `1b298b2` (Phase 13 merged)

## 達成したこと

### ✅ 1. 本番 D1 に Sequel migration 適用
```
$ npx wrangler d1 migrations apply homurabi-db --remote
┌───────────────────────┬────────┐
│ 0001_create_posts.sql │ ✅     │
└───────────────────────┴────────┘
```
- `db/migrations/0001_create_posts.rb` (Sequel DSL) → `0001_create_posts.sql`
- `wrangler.toml` の `[[d1_databases]]` に `migrations_dir = "db/migrations"` 追記
- Phase 12 で入れた migration パイプラインが production で end-to-end 動作確認済

### ✅ 2. `/posts` ルート追加
- `GET /posts` — Sequel Dataset DSL で一覧 (`seq_db[:posts].order(Sequel.desc(:id)).limit(20).all`)
- `POST /posts` — raw `db.get_first_row('INSERT ... RETURNING ...', [title, body])`
- Sequel Dataset#insert は SQLite 方言の inline-literal escape と D1 の parameterised-statement expectation がぶつかるので raw SQL 採用

### ✅ 3. Cookie-based login + /chat 認証必須化
- `GET /login` — フォーム (views/login.erb)
- `POST /login` — HMAC-SHA256 署名 cookie (`username:exp` を base64url) → `/chat` へ 303
- `GET /logout` — cookie delete → 302 `/`
- `GET /chat` — 未認証は `/login?return_to=/chat` へ 302
- **JWT ではなく HMAC 生**: JWT.encode は auto-await リストに入って async 化してしまい、Sinatra の `redirect` (`throw :halt`) と async 境界を越えて `UncaughtThrowError` になる。`OpenSSL::HMAC.hexdigest` は node:crypto 同期なのでルートが sync のまま保てる。

### ✅ 4. ナビゲーション整備
- `views/layout.erb` — About / D1 / Sequel / Posts / HTTP / Chat + Login/Logout
- `views/index.erb` — 「🌱 基本 / 🗄️ D1 + Sequel / 🔑 KV/R2 / 🔐 JWT / 🌐 HTTP / 🤖 Workers AI / 🧪 Self-tests」で分類、25+ ルートにアクセス可能

### ✅ 5. 全回帰テスト緑
`npm test`: 16 suites / 385 tests / 0 failed（Phase 13 と同じ）

### ✅ 6. 一度は本番デプロイ成功
commit `a3565cd` を deploy して live で:
- `POST /posts` → 201 + 新規 row
- `GET /posts` → 一覧
- `GET /chat` 未認証 → 302 /login
- `POST /login` → 303 + Set-Cookie
- `GET /chat` 認証済 → 200

## ⚠️ 残課題 — Cloudflare Workers 起動 CPU 時間制限

### 症状
```
Error: Script startup exceeded CPU time limit. [code: 10021]
```

`npx wrangler deploy` が初回 / 2回目は通るけど、再 deploy すると fail する現象。layout.erb 更新を反映させる 2nd deploy が通らず、nav が旧 version のまま。

### 根本原因

homurabi は Opal で Ruby → JS コンパイル → Workers 実行のアーキテクチャなので、バンドルが通常の JS Worker より桁違いに重い:

| 項目 | 通常 JS Worker | homurabi |
|---|---|---|
| バンドルサイズ | 数十 KB | **6.7 MB** |
| Gzip 後 | 数 KB | **1.3 MB** |
| 生 JS 行数 | 数千 | **119,629 行** |
| 起動時の仕事 | require 数個 | Opal runtime + Ruby stdlib + Rack + Sinatra 4.2.1 + JWT + Sequel + OpenSSL + Mustermann + **69 routes** の class_eval |

Cloudflare Workers の起動 CPU 時間制限は **~400ms (Paid Standard)**。homurabi は Phase 13 時点で 350-380ms で張り付き、Phase 14 で 5 routes + 補助ロジック追加 → 超過。

### 今日 Phase 14 でやった初期対策（それでも不足）

- `helpers do ... end` ブロック解除 → `Sinatra::Base` 直接 `def` に（module_eval 1回分節約）
- `before do; @current_user = ...; end` 削除 → layout.erb で直接 `current_session_user` 呼ぶ形に（filter registration 1個分節約）
- JWT.encode → HMAC.hexdigest 直接（async scope 化回避、startup には効かない）

これで「1回は」通るが「2回目」は通らない。CPU 計測のブレに依存。

### 次に打つべき対策 (Phase 15 候補)

優先度順:

#### ⭐️ A. Opal バンドル削減（本命）
`vendor/opal-gem/stdlib/` で homurabi 未使用のものを排除:
- `minitest*` — テストフレームワーク、本番不要
- `benchmark*` — ベンチマーク、本番不要
- `opal-parser` の中で runtime eval しか使わない部分（route の class_eval 用）を特定
- 一部 encoding テーブル (`iso-8859-*`, `windows-*`) — homurabi は UTF-8 / ASCII-8BIT だけ
- stringio の一部

想定効果: 起動 200-300ms（-30〜40%）、バンドル 4-5MB（-30%）

#### B. Mustermann dialect 削減
`vendor/mustermann/` は Sinatra / Regular 以外の dialect（Template, Rails, Shell など）も抱える。Sinatra 路線だけにすれば ~100KB / ~数万行削減見込み。

#### C. Sinatra extension 絞り込み
- Sinatra::ShowExceptions — production では不要
- Sinatra::CommonLogger — CF 側で logging あるので不要
- 一部 middleware

#### D. Cloudflare Workers CPU limit 引き上げ依頼
Cloudflare Dashboard から Workers Paid Standard → 数分で可能。ただし起動以外の per-request CPU も上がるので別課金影響あり。

#### E. Route の遅延登録（最後の手段）
Sinatra `get/post/...` を初回リクエスト時に compile する lazy evaluation にする。Sinatra 本体の大改修になるので避けたい。

### 関連: Deploy フローの遅さ

deploy ごとに Slack approval dialog が出て **30分タイムアウト**の承認待ちになる。`npx wrangler deploy` は destructive action 扱いのため。
- 今日は何度か 15-20分待ってから approval したけどタイミング ズレてリトライが詰まった
- **対策**: `~/.claude/settings.json` の permission 設定で `npx wrangler deploy` を allowlist 化するか、Slack 通知を短時間 timeout に変えるか検討余地あり

## ファイル変更サマリ

```
3 commits on feature/phase14-posts-login-navi
  app/hello.rb       (+197 -12)  posts routes / login routes / session helpers
  views/index.erb    (+ 55 -10)  拡充ナビ (25+ ルート分類)
  views/layout.erb   (+ 11 - 5)  Login/Logout 切替
  views/login.erb    (+ 33 新規)
  wrangler.toml      (+  6 新規) migrations_dir
```

## 次回セッション復帰時の手順

1. `git wt` / `git worktree list` で現在状態確認
2. 本 REPORT の「次に打つべき対策」A から着手
3. 削減して `npm run build` → `npm test` で回帰ゼロ確認 → `npx wrangler deploy --dry-run` で起動 CPU profile 取得
4. 安全に deploy 通るバンドルサイズに縮んでから本 deploy → PR `feature/phase14-posts-login-navi` 作成

## 現状
- Phase 14 コードは **ローカル全部動作、production 1回 deploy 済（旧 nav）**
- PR **未作成**（startup CPU 対策完了後に作る）
- posts 機能は live サイト `https://homurabi.kazu-san.workers.dev/posts` で **既に動作中**（最初の deploy が通ったため）
- ナビ / login UI は次 deploy で反映されるはず

## Phase 12.5 + 13 のマージ済 PR

- [PR #11](https://github.com/kazuph/homurabi/pull/11) — Phase 12.5: auto-await via Opal magic comment (merged)
- [PR #12](https://github.com/kazuph/homurabi/pull/12) — Phase 13: Sinatra upstream v4.2.1 + single-file patch (merged)
