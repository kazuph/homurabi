# Phase 17 — 本番実送信記録（Cursor）

## 実送信タイムスタンプ（UTC）

- **送信処理完了（HTTP 200）**: `2026-04-22T00:46:47Z`（メール本文 `Time:` フィールドと一致）

## Workers Version（subject に使用）

- **Version ID**: `a971976e-7f97-493a-b682-4a271621b45b`  
  （`wrangler deployments list` の一覧末尾 = デプロイ Created `2026-04-22T00:32:27Z` 付近）

## 認証

- `POST https://homurabi.kazu-san.workers.dev/login` に `username=kazuph`（このアプリは同期ルートでパスワード検証なしでセッション発行）。
- Cookie jar: `/tmp/p17-cookie.txt`（`homurabi_session`）。

## 成功した POST（`/debug/mail`）

- **形式**: `application/x-www-form-urlencoded`
- **注意**: `--data-urlencode` で `to` を渡すと `@` が `%40` のまま API に届き **`E_VALIDATION_ERROR`（invalid recipient）** になるため、**`-d "to=kazu.homma@gmail.com"` のように素の `@` で送る**こと。

### レスポンス JSON（本文 `<pre>` から復元）

```json
{
  "ok": true,
  "message_id": "<5TsIqnKxnOouoi7rr8sE9787e21VFiI1OyDR@kazuph-info.ai-work.uk>",
  "cf_send_result_json": "{\"messageId\":\"<5TsIqnKxnOouoi7rr8sE9787e21VFiI1OyDR@kazuph-info.ai-work.uk>\"}",
  "to": "kazu.homma@gmail.com",
  "from": "noreply@kazuph-info.ai-work.uk",
  "subject": "homurabi Phase 17 test — Version a971976e-7f97-493a-b682-4a271621b45b"
}
```

- **message_id（短縮表示用）**: `<5TsIqnKxnOouoi7rr8sE9787e21VFiI1OyDR@kazuph-info.ai-work.uk>`

### リクエスト本文（text）

```
This is a test mail from homurabi Phase 17 (Cloudflare Email Service public beta). Time: 2026-04-22T00:46:47Z
```

※ `from` フォーム値はアプリ側では未使用（`HOMURABI_MAIL_FROM` = `noreply@kazuph-info.ai-work.uk` が実送信元）。

## 失敗試行（参考）

1. **宛先**: `--data-urlencode to=...` → `kazu.homma%40gmail.com` となり Cloudflare API が「Missing domain or user」。
2. **ログイン**: `curl -L` 追従で最終コードが 404 になることがあるが、**Set-Cookie は取得済み**のため `/debug/mail` にはセッション付きで到達可能。

## wrangler tail

- `wrangler tail homurabi` を短時間実行し、リクエスト JSON ログの先頭行が取得できることを確認（詳細ログはローカル環境依存）。

---

**マスターへ**: Gmail（`kazu.homma@gmail.com`）での着信確認をお願いします。件名は `homurabi Phase 17 test — Version a971976e-7f97-493a-b682-4a271621b45b` です。

---

## HTML + plain 複合送信（2026-04-22）

- **デプロイ Version ID（wrangler deploy 出力）**: `6772a870-a1ea-4400-b8df-ff38f9e1a3a0`
- **送信時刻（UTC, HTML に埋め込み）**: `2026-04-22T00:59:48Z`

### curl 例（`html` は `--data-urlencode` で渡す）

```bash
curl -sS -b /tmp/p17-cookie.txt -X POST https://homurabi.kazu-san.workers.dev/debug/mail \
  -d "to=kazu.homma@gmail.com" \
  --data-urlencode "subject=homurabi Phase 17 HTML test — Version 6772a870-a1ea-4400-b8df-ff38f9e1a3a0" \
  --data-urlencode "text=Plain text fallback (HTML 非対応クライアント用)" \
  --data-urlencode "html=<h1>...</h1><p>...</p>"
```

※ 実際の応答では `subject` に CF-Ray 由来サフィックス（` — 9f00b0389a569160` 等）が付く場合あり（`/debug/mail` の既定ロジック）。

### レスポンス JSON（復元）

```json
{
  "ok": true,
  "message_id": "<kH3DLrWLa83L2NfQTqYcP99yJfsDKQ9K2vPc@kazuph-info.ai-work.uk>",
  "cf_send_result_json": "{\"messageId\":\"<kH3DLrWLa83L2NfQTqYcP99yJfsDKQ9K2vPc@kazuph-info.ai-work.uk>\"}",
  "to": "kazu.homma@gmail.com",
  "from": "noreply@kazuph-info.ai-work.uk",
  "subject": "homurabi Phase 17 HTML test — Version 6772a870-a1ea-4400-b8df-ff38f9e1a3a0 — 9f00b0389a569160"
}
```

### Plain text のみ（回帰）

- **subject**: `Phase17 plain-only smoke`
- **message_id**: `<wEpgiTbXQed97aTYRqdZo9YRn8b40noTwIWG@kazuph-info.ai-work.uk>` （HTTP 200、`ok: true`）

---

**マスターへ（HTML メール）**: Gmail でマルチパート（plain + HTML）の表示を確認してください。件名キーワード `Phase 17 HTML test`。

---

## HTML CONFIRMATION 送信（明示的な件名・スタイル確認用）

**ドキュメント準拠**: `to` は **素の `@`**（`-d "to=..."`）。`html` / `text` / `subject` は **`--data-urlencode`** または **`--data-urlencode html@ファイル`**（長い HTML をシェルで壊さない）。

- **送信時刻（UTC 概算）**: 実実行直後（Cloudflare 応答 HTTP 200）
- **件名（意図）**: `homurabi Phase 17 HTML CONFIRMATION (太字+リスト+リンク表示確認)`  
  ※ form-urlencoded により Cloudflare 応答 JSON 上は `+` が `%2B` 表記になることがある（受信側は通常デコードされる）。

### レスポンス JSON（復元）

```json
{
  "ok": true,
  "message_id": "<3bKVIsJnguzE9gjQt0BXP51yKwGwWRggFS33@kazuph-info.ai-work.uk>",
  "cf_send_result_json": "{\"messageId\":\"<3bKVIsJnguzE9gjQt0BXP51yKwGwWRggFS33@kazuph-info.ai-work.uk>\"}",
  "to": "kazu.homma@gmail.com",
  "from": "noreply@kazuph-info.ai-work.uk",
  "subject": "homurabi Phase 17 HTML CONFIRMATION (太字+リスト+リンク表示確認) — 9f00be87ee1dd534"
}
```

- **text**: `これは HTML メールの fallback 文字列です`
- **html**: スタイル付き `<h1>` / `<strong>` / `<em>` / `<ul>` / `<a href="https://homurabi.kazu-san.workers.dev/docs/email">` 等（長文は `/tmp/homurabi-html-confirmation.txt` に保存して `html@` で POST）。

### curl 例

```bash
curl -sS -b /tmp/p17-cookie.txt -X POST https://homurabi.kazu-san.workers.dev/debug/mail \
  -d "to=kazu.homma@gmail.com" \
  --data-urlencode "subject=homurabi Phase 17 HTML CONFIRMATION (太字+リスト+リンク表示確認)" \
  --data-urlencode "text=これは HTML メールの fallback 文字列です" \
  --data-urlencode "html@/tmp/homurabi-html-confirmation.txt"
```

**マスターへ**: 件名に **HTML CONFIRMATION** と **太字+リスト+リンク** が含まれるメールで、Gmail でリッチ表示を確認してください。

---

## HTML が Gmail でレンダリングされなかった根本原因と修正（2026-04-22）

参考: [Workers Email API — send](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/)（`html` / `text` は任意組み合わせ・multipart）。

### 原因（X）

`build_send_payload` で `payload.subject` / `.text` / `.html` に **Opal の String オブジェクトをそのまま代入**していた。ランタイム上は `typeof payload.html === 'object'` となりうる。**Cloudflare Email の `binding.send(payload)` がプレーン JS の `string` を期待しているため、multipart の HTML 側が効かず text のみになっていた**。

### 修正（Y）

`gems/cloudflare-workers-runtime/lib/cloudflare_workers/email.rb` で **`subject` / `text` / `html` 代入時に `.toString()`（JS の primitive string）へ正規化**した。

### wrangler tail での実証（デバッグビルド / Version `d851aa61-0315-445c-9639-cf0d6b6a23e2`）

`binding.send` 直前に一時的に `console.log` を入れたデプロイで `/debug/mail` を POST。`logs` に以下が記録された（要旨）:

```json
{
  "subject_type": "string",
  "text_type": "string",
  "html_type": "string",
  "subject_len": 75,
  "text_len": 28,
  "html_len": 384,
  "html_head": "<h1 style=\\\"color:#f6821f;\\\">HTML 表示確認</h1>..."
}
```

※ `html_head` は URL エンコードされたフォーム由来で `%3D` 等が混ざるが、**`html_type` が `"string"` であること**が物理的な根拠。

### 修正後の本番デプロイ

- **ログ除去後の Version ID**: `a58bbf47-f411-446b-b4f2-45169fa1b4a3`

### 再送信（修正後・ログなしビルド）

- **message_id**: `<Fjgso94lijW0Ipw9tOdd8SVCkLzlGTWOGGmt@kazuph-info.ai-work.uk>`
- **件名**: `homurabi Phase 17 HTML CONFIRMATION (太字+リスト+リンク表示確認)`（末尾に CF-Ray 由来の短いサフィックスが付く場合あり）

デバッグ送信時の message_id（同一修正コード・ログ付きビルド）: `<Jr6YtZkTkdrWbhlk9CP4ep5V1xhB0yrEfCPN@kazuph-info.ai-work.uk>`（HTTP 200）。

**マスターへ**: 上記 **再送信分**（`Fjgso94li…`）で Gmail の HTML 表示を確認してください。届かない場合はスパム／セグメントを確認。

---

## Phase 17 リファクタ承認後・本番 HTML+text 再送信（2026-04-22）

### Git / デプロイ整合性

- **リポジトリ**: `4b67c65`（fragments dedent までのリファクタ列）は **現在の `HEAD` の祖先**（`merge-base --is-ancestor 4b67c65 HEAD` が真）。
- **実送信時の Workers Version ID**（`wrangler deploy` 出力）: `7ccb9d4f-a98d-4281-aad7-5d8460f2b388`
- **ログプローブ除去後の本番 Version ID**（現行トラフィック想定）: `1412a612-e397-4f9d-b090-122177aa91c0`

### POST `/debug/mail`（admin セッション・multipart）

- **to**: `kazu.homma@gmail.com`（`-d "to=..."` で素の `@`）
- **subject（意図）**: `homurabi Phase 17 refactor verification — 7ccb9d4f-a98d-4281-aad7-5d8460f2b388`  
  ※ **応答 JSON 上の subject** には既存ロジックにより **CF-Ray 由来の短いサフィックス**（例: ` — 9f00eb76cc9b80f0`）が **追加**される場合あり。
- **text**: `Refactor 後の plain fallback`
- **html**: `<h1 style="color:#f6821f;">` … `Homurabi::DebugMailController` …（スタイル付きブロック全文は送信時と同一）

### レスポンス JSON（復元）

```json
{
  "ok": true,
  "message_id": "<LFz7G3g9vfNv5rXP8HbMMqZMmpXBovSBUEYJ@kazuph-info.ai-work.uk>",
  "cf_send_result_json": "{\"messageId\":\"<LFz7G3g9vfNv5rXP8HbMMqZMmpXBovSBUEYJ@kazuph-info.ai-work.uk>\"}",
  "to": "kazu.homma@gmail.com",
  "from": "noreply@kazuph-info.ai-work.uk",
  "subject": "homurabi Phase 17 refactor verification — 7ccb9d4f-a98d-4281-aad7-5d8460f2b388 — 9f00eb76cc9b80f0"
}
```

- **HTTP**: 200（送信処理完了）

### wrangler tail（`binding.send(payload)` 直前・型・長さのみ）

一時的に `Cloudflare::Email` の async IIFE 内で `console.log(JSON.stringify({ homurabi_send_email_payload: … }))` を挿入したビルド **Version `bfb904b8-5fc7-4297-8ee4-29fa8557312d`** で `/debug/mail` を POST。`logs` に以下が記録された（**`html_type` が `"string"`** であることが multipart 経路の物理的根拠）:

```json
{"homurabi_send_email_payload":{"html_type":"string","text_type":"string","subject_type":"string","html_len":217,"text_len":10}}
```

※ 上記プローブ行は **記録後にコードから除去**し、**Version `1412a612-e397-4f9d-b090-122177aa91c0`** を再デプロイ済み（本番はログノイズなし）。

### スモーク（本番 GET 11 ルート・HTTP 200）

`/`, `/posts`, `/about`, `/login`, `/docs`, `/docs/email`, `/docs/quick-start`, `/docs/migration`, `/docs/sinatra`, `/docs/sequel-d1`, `/docs/runtime`, `/docs/architecture`

### 検証時刻（UTC）

`2026-04-22T01:43:34Z` 時点で `npm test` 全スイート PASS。

**マスターへ**: 件名に **`Phase 17 refactor verification`** と **Version UUID** が含まれるメールで、Gmail で **HTML レンダリング**（オレンジ見出し・太字・コード表示）を確認してください。問題なければ Phase 17 マージ判断で構いません。
