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
