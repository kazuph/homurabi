# auth-otp

> 🇬🇧 English version: [README.md](README.md)

> Cloudflare Workers 上で動くメールOTPログイン。OTP の行は **D1**
> に保存し、開発時のメール送信は [**mailpit**](https://mailpit.axllent.org/)
> 経由、セッションは **HMAC 署名付き Cookie** で保持する。

本番環境では mailpit の HTTP エンドポイントを SES / SendGrid / Resend /
Cloudflare Email Workers などに差し替えるだけでよく、それ以外のコードは
そのまま使える。

## このサンプルで示しているもの

- 実用的な認証フロー（`/login` → `/verify` → `/`）を扱う Sinatra アプリ。
- D1 に保存した OTP を `expires_at` カラムで TTL 管理。
- `format('%06d', SecureRandom.random_number(1_000_000))` という Ruby の
  定番イディオム。Workers 上でも **きちんと一様分布の 6 桁 OTP** を返し、
  古い opal-homura ビルドのように常に 0 になることはない。
- `+` を含むメールアドレスでも HMAC 署名付きセッション Cookie が
  ラウンドトリップで壊れない。これは `sinatra-homura` 0.2.17 の
  `parse_cookies_header` パッチ（`CGI.unescapeURIComponent` を使い、
  form-data の `+` → スペース変換を避ける）のおかげ。
- Worker から mailpit へは `Cloudflare::HTTP.fetch` でローカル HTTP API
  （`POST http://127.0.0.1:8025/api/v1/send`）に投げる。
- Ruby で書かれた E2E テストハーネスを 2 種類用意:
  - `rake e2e`（Net::HTTP）: CI フレンドリーなスモークテスト。
  - `rake e2e:headed`（`playwright-ruby-client` + Chromium）: 目視確認用。
    PNG スナップショットと毎回の `.webm` 録画を残す。

## ルーティング

| Method | Path | 動作 |
|---|---|---|
| `GET`  | `/` | ログイン済み: `Hello <email>!` とログアウトボタン。未ログイン: `/login` へのリンク。 |
| `GET`  | `/login` | メールアドレス入力フォーム。 |
| `POST` | `/login` | 6 桁 OTP を発行し、`(email, code, expires_at)` を D1 に保存、mailpit 経由でメール送信、`/verify?email=...` へリダイレクト。 |
| `GET`  | `/verify` | 6 桁コードの入力フォーム。 |
| `POST` | `/verify` | 該当 `email` の最新かつ未失効の行を照合。成功したら署名付き `session` Cookie をセットして `/` へリダイレクト。 |
| `POST` | `/logout` | Cookie を破棄し `/login` へリダイレクト。 |

## ディレクトリ構成

```
auth-otp/
├── Gemfile                       # + playwright-ruby-client (development)
├── Rakefile                      # build/dev/deploy + db:migrate:* + mailpit:* + e2e + e2e:headed
├── wrangler.toml                 # D1 binding "DB" → database "auth-otp"
├── app/app.rb                    # routes + signed-cookie helpers
├── views/{layout,index,login,verify}.erb
├── db/migrate/
│   ├── 001_create_otps.rb        # Sequel DSL
│   └── 001_create_otps.sql       # compiled output
├── public/robots.txt
└── tmp/e2e-headed/               # screenshots + .webm from `rake e2e:headed`
```

## エンドツーエンドの流れ

```
                  ┌────────────────────┐  fetch http://127.0.0.1:8025/api/v1/send
       /login ───►│  Cloudflare Worker │ ──────────────────────────────────────────►  mailpit (8025)
                  │  (Sinatra, D1)     │                                                 │
                  └────────────────────┘                                                 │
                          │                                                              │
                  insert OTP into D1                                                     │
                          │                                                              │
                       redirect /verify?email=...                                        │
                          │                                                              ▼
       /verify ─► validate code → set Set-Cookie: session=<email>.<HMAC> → redirect /
```

## コードのハイライト

```ruby
def generate_otp
  format('%06d', SecureRandom.random_number(1_000_000))   # 標準的な Ruby のイディオム
end

def sign_email(email)
  OpenSSL::HMAC.hexdigest('SHA256', SESSION_SECRET, email)
end

def encode_session_token(email)
  "#{email}.#{sign_email(email)}"                          # 素のメールアドレス。hex 変換は不要
end

post '/login' do
  email = params[:email].to_s.strip
  halt 422, 'invalid email' unless email.match?(EMAIL_RE)
  code = generate_otp
  db.execute_insert(
    'INSERT INTO otps (email, code, expires_at) VALUES (?, ?, ?)',
    [email, code, Time.now.to_i + 300]
  )
  send_otp_via_mailpit(email, code)
  redirect "/verify?email=#{Rack::Utils.escape(email)}"
end
```

## 動かしてみる（開発環境）

```bash
cd examples/auth-otp
bundle install
npm install

bundle exec rake db:migrate:local         # ローカル D1 に otps テーブルを作成
bundle exec rake mailpit:start            # 127.0.0.1:1025/8025 で mailpit を起動
bundle exec rake build
bundle exec rake dev                      # http://auth-otp.localhost:1355/
```

そのうえで:

- <http://auth-otp.localhost:1355/login> を開き、任意のメールアドレスを入力して送信。
- <http://127.0.0.1:8025>（mailpit の Web UI）を開き、受信したメールから 6 桁コードを取り出す。
- そのコードを `/verify` に貼り付けて送信すればログイン完了。

## Net::HTTP を使った E2E

```bash
bundle exec rake e2e
# [e2e] base=http://auth-otp.localhost:1355 email=demo+1777289470@example.com
# [e2e] /login → 200
# [e2e] mailpit mail received id=... otp=310597
# [e2e] /verify → 303
# [e2e] / shows logged-in email
# [e2e] /logout → 303
# E2E OK: email=demo+1777289470@example.com, otp=310597
```

連続で 2 回実行すると OTP が毎回違う値になる。これは
`SecureRandom.random_number` がきちんとエントロピーを持っている
ことの証拠でもある。

## 実ブラウザでの E2E（headed モード）

```bash
bundle exec rake e2e:headed
```

`playwright-ruby-client` 経由で Chromium を起動し、`slowMo: 350` を
かけた状態で同じフローを実行するので目視で確認できる。出力先は
以下のとおり:

- `tmp/e2e-headed/01-top-unauth.png`
- `tmp/e2e-headed/02-login-filled.png`
- `tmp/e2e-headed/03-after-login.png`
- `tmp/e2e-headed/04-verify-filled.png`
- `tmp/e2e-headed/05-after-verify.png`  ← `Hello demo+...@example.com!`
- `tmp/e2e-headed/06-after-logout.png`
- `tmp/e2e-headed/page@<hash>.webm`     ← 全体の録画

## 本番への切り替え

本番化に必要な変更は 2 点だけ:

1. **メール送信のトランスポート。** `send_otp_via_mailpit` の中身を、
   利用するプロバイダ（SES / SendGrid / Resend / Cloudflare Email
   Workers など）への `Cloudflare::HTTP.fetch` 呼び出しに置き換える。

2. **`SESSION_SECRET`。** Wrangler の secret として設定する:

   ```bash
   npx wrangler secret put SESSION_SECRET
   ```

リモートの D1 セットアップは `homura new --with-db` の標準的な
フローで完結する:

```bash
npx wrangler d1 create auth-otp                     # 一度だけ実行
# 出力された database_id を wrangler.toml に貼り付ける
bundle exec rake db:migrate:remote
bundle exec rake deploy
```
