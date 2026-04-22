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
