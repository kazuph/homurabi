# ai-voice-chat

The third Workers AI example: audio in, transcript out, Kimi K2.6 reply, and
Aura speech playback. When the reply contains Japanese text, the app rewrites
it into romaji before sending it to Aura so the spoken output stays usable on
the current `@cf/deepgram/aura-1` surface.

## Routes

- `GET /` — upload + speaker selection UI
- `POST /chat` — Whisper transcription + Kimi reply + romaji TTS script +
  inline Aura audio

## Local run

```bash
bundle install
npm install
bundle exec rake build
bundle exec rake dev
```

Local dev is open by default. Production deploys should set a secret token and
open the page as `/?token=...`.

## Deploy

```bash
wrangler secret put VOICE_CHAT_TOKEN
bundle exec rake deploy
```

The page stays JavaScript-free by embedding the Aura MP3 as a data URL in the
HTML response.

## Cost guard

- `VOICE_CHAT_TOKEN` (secret) — required in production; requests without the
  matching `?token=...` return 404.
- `VOICE_CHAT_DAILY_LIMIT` (var, default `20`) — maximum number of POST `/chat`
  attempts per UTC day, enforced with a Durable Object counter before any AI
  call runs. Failed attempts still count; that is intentional so the limit
  caps spend rather than only successful responses.
