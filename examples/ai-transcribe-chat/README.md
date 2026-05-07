# ai-transcribe-chat

The second Workers AI example: record audio in the browser, transcribe it with
Whisper, then send the transcript to Kimi K2.6.

## Routes

- `GET /` — browser microphone UI
- `POST /chat` — Whisper transcription + Kimi reply

## Local run

```bash
bundle install
npm install
bundle exec rake build
bundle exec rake dev
```

The page uses `getUserMedia` + `MediaRecorder` to capture one clip in the
browser, then submits that recording as a normal multipart form upload to the
Sinatra route.

## Deploy

```bash
bundle exec rake deploy
```
