# auth-otp — メールOTPログイン (D1 + mailpit)

homura (Sinatra on Cloudflare Workers) で構築した、メールOTPログインの実装例です。
**OTP は D1 に永続化し、mailpit (ローカルSMTP/HTTP API) にメール送信します。**
本番デプロイ時は mailpit URL を SES / SendGrid / Resend / Cloudflare Email Workers などへ差し替えてください。

## 構成

- セッション: 署名Cookie `session = "<hex(email)>.<HMAC-SHA256(email, SECRET)>"`
  - `OpenSSL::HMAC.hexdigest('SHA256', SECRET, email)` で 16進署名
  - email 部分は hex エンコード（Rack の cookie 読み書きが `+` などをデコードして HMAC が壊れるのを回避）
  - HMAC は homura-runtime の Web Crypto bridge で sync 動作するため、`redirect` を使う sync ルートで安全
- OTPストア: D1 テーブル `otps (id, email, code, expires_at)`
  - `expires_at` は UNIX 秒。`/verify` は `expires_at >= now` の最新行を取得
  - 検証成功で `DELETE FROM otps WHERE email = ?`（同 email の古い行ごとワンショット失効）
- メール送信: Worker から mailpit の HTTP Send API (`POST http://127.0.0.1:8025/api/v1/send`) を `Cloudflare::HTTP.fetch` でコール
  - `wrangler dev --local` モードでは Worker → 127.0.0.1:8025 への fetch が直接到達できる
  - 失敗時は dev フォールバックとして OTP を画面表示
- セッションシークレット: `ENV['SESSION_SECRET']` → なければ `'dev-secret-change-me'`

## ルート

| Method | Path | 内容 |
|---|---|---|
| GET  | `/` | Cookie検証。ログイン中は "Hello <email>" + Logoutボタン、未ログインは /login へリンク |
| GET  | `/login` | email入力フォーム |
| POST | `/login` | OTPを D1 に保存し、mailpit 経由でメール送信。成功で /verify ページへ |
| GET  | `/verify` | email + code入力フォーム |
| POST | `/verify` | OTP照合。成功で署名Cookieセット → `/` に 303 redirect |
| POST | `/logout` | Cookie削除 → `/login` に 303 redirect |

## 初期セットアップ

```bash
bundle install

# D1 ローカルマイグレーション
bundle exec rake db:migrate:local

# Opal + Workers バンドル
bundle exec rake build

# portless プロキシ起動 (常駐)
portless proxy start

# mailpit 起動 (SMTP:1025, Web UI/API:8025)
bundle exec rake mailpit:start
```

## 起動と動作確認

```bash
# dev サーバを portless 経由で起動 (http://auth-otp.localhost:1355/)
nohup bundle exec rake dev > /tmp/auth-otp-dev.log 2>&1 &
sleep 18

# E2E スモークテスト (portless + mailpit + D1)
bundle exec rake e2e
```

mailpit Web UI: http://127.0.0.1:8025/

`rake e2e` は次を行います:

1. `/login` に email を POST して OTP を発行
2. mailpit HTTP API からメールを取得し、本文から 6 桁 OTP を抽出
3. `/verify` に email + code を POST し、Set-Cookie を取得
4. cookie 付きで `/` を GET し、`Hello <email>` が出ることを確認
5. `/logout` で Cookie 削除

## 公開gem構成

`Gemfile` は `path:` / `git:` を一切使わず、rubygems.org で公開されている
`opal-homura` / `homura-runtime` / `sinatra-homura` / `sequel-d1` / `sequel` / `sqlite3` のみを使用しています。

## 実装上の注意 (Opal/Workers環境)

- **OTP生成**: `SecureRandom.random_number(1_000_000)` は現在の Opal ビルドで
  常に `0` を返す（`Random::Formatter#random_float` が integer division で 0 になる）。
  代わりに `SecureRandom.hex(4).to_i(16) % 1_000_000` で 6 桁を作っている。
- **Cookie形式**: 値は `<hex(email)>.<HMAC-hex64>`。email を hex エンコードする理由:
  Rack の cookie 書き込みは生の `+` を許容する一方、読み込み側 (`request.cookies`) は
  値を percent-decode するため、`demo+foo@x.com` のような email がラウンドトリップで
  `demo foo@x.com` に化け、HMAC 検証が落ちる。hex 化で `[0-9a-f]` のみに揃えて回避。
- **`halt` 禁止**: async Sinatra では `halt` の `:halt` throw が async boundary を
  跨げない。本例は同期ルートと、`# await:` 指定の D1 / fetch 呼び出しで構成し、
  画面遷移は `redirect path, 303` を使う。
- **D1 マイグレーション**: `db:migrate:compile` で Sequel migration を SQL に変換した後、
  D1 (local sqlite shim) が拒否する probe 文 (`SELECT sqlite_version()`,
  `SELECT NULL AS 'nil' FROM <table> LIMIT 1`) を Rakefile 側で除去している。
- **mailpit fetch**: Worker → `127.0.0.1:8025` への HTTP は `wrangler dev --local`
  モードであれば host network 経由で素直に通る。本番では mailpit URL を外部 SMTP HTTP
  サービス (Resend など) に差し替える。
