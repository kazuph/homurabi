# frozen_string_literal: true

require "json"
require "sinatra"

CHAT_MODEL = "@cf/moonshotai/kimi-k2.6"
SYSTEM_PROMPT = "You are a helpful assistant. Reply to the spoken message clearly and keep the answer under 280 characters."
  .freeze
ROMAJI_SYSTEM_PROMPT = "You rewrite Japanese text into simple romaji for text-to-speech. Return only lowercase ASCII romaji with spaces and basic punctuation. Do not translate into English, do not explain, and do not use kana, kanji, markdown, or code fences."
  .freeze
MAX_AUDIO_BYTES = 5 * 1024 * 1024
MAX_REPLY_CHARS = 280
DEFAULT_DAILY_LIMIT = 20
LANGUAGES = {
  "auto" => "Auto detect",
  "en" => "English",
  "ja" => "Japanese"
}.freeze
SPEAKERS = {"luna" => "Luna", "stella" => "Stella", "orion" => "Orion"}.freeze
DEFAULT_SPEAKER = "luna"
VOICE_LIMIT_DO_CLASS = "HomuraCounterDO"
VOICE_LIMIT_DO_NAME = "voice-tts".freeze

class VoiceChatConfigError < StandardError
end

class VoiceChatDailyLimitError < StandardError
  attr_reader :remaining

  def initialize(message, remaining: 0)
    @remaining = remaining.to_i
    super(message)
  end
end

Cloudflare::DurableObject.define(VOICE_LIMIT_DO_CLASS) do |state, request|
  payload = request.json
  day = payload["day"].to_s.strip
  limit = payload["limit"].to_i
  headers = {"content-type" => "application/json"}

  if day.empty? || !limit.positive?
    next 400, headers, {"error" => "day and limit are required"}.to_json
  end

  key = "count:#{day}"
  count = (state.storage.get(key) || 0).to_i
  remaining = [limit - count, 0].max
  base = {
    "day" => day,
    "limit" => limit,
    "count" => count,
    "remaining" => remaining
  }

  if request.path.end_with?("/reserve")
    if count >= limit
      [429, headers, base.merge("allowed" => false).to_json]
    else
      next_count = count + 1
      state.storage.put(key, next_count)
      [
        200,
        headers,
        base
          .merge(
            "count" => next_count,
            "remaining" => [limit - next_count, 0].max,
            "allowed" => true
          )
          .to_json
      ]
    end
  else
    [200, headers, base.to_json]
  end
end

def h(text)
  Rack::Utils.escape_html(text.to_s)
end

def dev_host?
  host = request.host.to_s
  host == "localhost" || host == "127.0.0.1" || host.end_with?(".localhost")
end

def cf_env_var(name)
  return "" unless cf_env
  `(#{cf_env}[#{name}] || '')`.to_s.strip
end

def voice_chat_token
  cf_env_var("VOICE_CHAT_TOKEN")
end

def voice_chat_daily_limit
  raw = cf_env_var("VOICE_CHAT_DAILY_LIMIT")
  return DEFAULT_DAILY_LIMIT if raw.empty?
  value = raw.to_i
  value.positive? ? value : DEFAULT_DAILY_LIMIT
end

def normalize_speaker(name)
  key = name.to_s
  SPEAKERS.key?(key) ? key : DEFAULT_SPEAKER
end

def normalize_language(name)
  key = name.to_s
  LANGUAGES.key?(key) ? key : "auto"
end

def language_options(selected)
  current = normalize_language(selected)
  LANGUAGES
    .map do |value, label|
      selected_attr = value == current ? " selected" : ""
      "<option value=\"#{h(value)}\"#{selected_attr}>#{h(label)}</option>"
    end
    .join
end

def speaker_options(selected)
  current = normalize_speaker(selected)
  SPEAKERS
    .map do |value, label|
      selected_attr = value == current ? " selected" : ""
      "<option value=\"#{h(value)}\"#{selected_attr}>#{h(label)}</option>"
    end
    .join
end

def microphone_icon
  <<~SVG
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v4.5m0 0H8.25m3.75 0h3.75M12 15.75A3 3 0 0 1 9 12.75V6a3 3 0 1 1 6 0v6.75a3 3 0 0 1-3 3Z"/>
    </svg>
  SVG
end

def page(
  transcript: nil,
  reply: nil,
  spoken_script: nil,
  audio_src: nil,
  speaker: DEFAULT_SPEAKER,
  language: "auto",
  token: nil,
  daily_remaining: nil,
  error: nil
)
  error_html = error ? "<p class=\"error\" role=\"alert\">#{h(error)}</p>" : ""
  token_html = if token.to_s.empty?
    ""
  else
    "<input type=\"hidden\" name=\"token\" value=\"#{h(token)}\">"
  end

  quota_html = if daily_remaining.nil?
    ""
  else
    "<p class=\"meta\"><strong>Daily attempts remaining:</strong> #{h(daily_remaining)}</p>"
  end

  transcript_html = (
    if transcript
      "<section><h2>Transcript</h2><pre>#{h(transcript)}</pre></section>"
    else
      ""
    end
  )
  spoken_script_html = (
    if spoken_script && spoken_script != reply
      <<~HTML
        <section>
          <h2>Spoken script</h2>
          <pre>#{h(spoken_script)}</pre>
        </section>
      HTML
    else
      ""
    end
  )
  reply_html = if reply
    <<~HTML
      <section>
        <h2>Kimi reply</h2>
        <pre>#{h(reply)}</pre>
        <audio controls autoplay src="#{h(audio_src)}"></audio>
      </section>
    HTML
  else
    ""
  end

  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>ai-voice-chat</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #05080f;
          --panel: rgba(14, 20, 33, .84);
          --panel-edge: rgba(255, 255, 255, .08);
          --text: #eef6ff;
          --muted: #aebdcb;
          --accent: #51d0ff;
          --accent-strong: #0bb7ff;
          --accent-soft: rgba(81, 208, 255, .16);
          --focus: #ffe27a;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          font-family: "Avenir Next", "Hiragino Sans", sans-serif;
          line-height: 1.5;
          color: var(--text);
          background:
            radial-gradient(circle at top, rgba(81, 208, 255, .18), transparent 30rem),
            radial-gradient(circle at bottom right, rgba(124, 92, 255, .16), transparent 30rem),
            linear-gradient(180deg, #09111d, var(--bg));
        }
        main { max-width: 56rem; margin: 0 auto; padding: 2.5rem 1rem 4rem; }
        h1 {
          margin: 0;
          font-size: clamp(2.8rem, 8vw, 5.1rem);
          line-height: .95;
          letter-spacing: -.05em;
        }
        p.note, p.meta, p.status { color: var(--muted); }
        .hero,
        section {
          background: var(--panel);
          border: 1px solid var(--panel-edge);
          border-radius: 2rem;
          padding: 1.35rem;
          backdrop-filter: blur(14px);
          box-shadow: 0 24px 60px rgba(0, 0, 0, .34);
        }
        .hero { margin-top: 1.3rem; }
        .hero-copy { max-width: 38rem; }
        .hero-copy p { margin: .85rem 0 0; }
        form { margin-top: 1.25rem; }
        label {
          display: block;
          margin-bottom: .5rem;
          font-size: .94rem;
          font-weight: 700;
          letter-spacing: .04em;
          text-transform: uppercase;
          color: #f3fbff;
        }
        select {
          width: 100%;
          margin-bottom: 1rem;
          padding: .9rem 1rem;
          border: 1px solid rgba(255, 255, 255, .12);
          border-radius: 1rem;
          font: inherit;
          color: inherit;
          background: rgba(255, 255, 255, .05);
        }
        select:focus-visible,
        .record-button:focus-visible {
          outline: 3px solid var(--focus);
          outline-offset: 4px;
        }
        input[type=file] { display: none; }
        .record-button {
          display: grid;
          place-items: center;
          gap: .7rem;
          width: min(100%, 18.5rem);
          aspect-ratio: 1;
          margin: 1.45rem auto .8rem;
          border: 0;
          border-radius: 50%;
          cursor: pointer;
          color: inherit;
          background:
            radial-gradient(circle at 35% 30%, #e9fbff, transparent 24%),
            radial-gradient(circle at center, #47d7ff, var(--accent-strong) 72%);
          box-shadow:
            0 0 0 1px rgba(255, 255, 255, .12),
            0 28px 50px rgba(11, 183, 255, .28),
            0 0 0 18px var(--accent-soft);
          transition: transform .18s ease, box-shadow .18s ease, filter .18s ease;
        }
        .record-button:hover { transform: translateY(-2px) scale(1.01); }
        .record-button[data-state="recording"] {
          animation: pulse 1.4s ease-in-out infinite;
          box-shadow:
            0 0 0 1px rgba(255, 255, 255, .12),
            0 0 0 20px rgba(11, 183, 255, .16),
            0 0 0 40px rgba(11, 183, 255, .08);
        }
        .record-button[disabled] {
          cursor: progress;
          opacity: .82;
          filter: grayscale(.1);
        }
        .record-icon {
          display: grid;
          place-items: center;
          width: 4.5rem;
          height: 4.5rem;
          border-radius: 999px;
          background: rgba(255, 255, 255, .96);
          color: var(--accent-strong);
          box-shadow:
            inset 0 0 0 1px rgba(255, 255, 255, .32),
            0 12px 24px rgba(0, 0, 0, .16);
        }
        .record-icon svg {
          width: 2.55rem;
          height: 2.55rem;
        }
        .record-label {
          max-width: 12rem;
          font-size: 1.1rem;
          font-weight: 800;
          line-height: 1.15;
          text-align: center;
          letter-spacing: .01em;
        }
        .status {
          min-height: 1.5rem;
          margin: .7rem 0 0;
          text-align: center;
        }
        section { margin-top: 1rem; }
        h2 {
          margin: 0 0 .75rem;
          font-size: .95rem;
          letter-spacing: .08em;
          text-transform: uppercase;
          color: #effbff;
        }
        pre {
          margin: 0 0 1rem;
          white-space: pre-wrap;
          font: inherit;
        }
        audio { width: 100%; }
        .error {
          margin-top: 1rem;
          color: #ffd7d7;
          font-weight: 700;
        }
        .sr-only {
          position: absolute;
          width: 1px;
          height: 1px;
          padding: 0;
          margin: -1px;
          overflow: hidden;
          clip: rect(0, 0, 0, 0);
          white-space: nowrap;
          border: 0;
        }
        @keyframes pulse {
          0%, 100% { transform: scale(1); }
          50% { transform: scale(1.04); }
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after {
            animation-duration: .01ms !important;
            animation-iteration-count: 1 !important;
            transition-duration: .01ms !important;
          }
        }
      </style>
    </head>
    <body>
      <main>
        <section class="hero">
          <div class="hero-copy">
            <h1>Talk, then hear it back.</h1>
            <p class="note">The browser records your microphone, Whisper transcribes it, Kimi writes the answer, and Aura reads the final script aloud.</p>
            <p class="note">When Kimi replies in Japanese, the app rewrites the answer into romaji before speech playback. The daily cap is consumed before any AI call runs, so failed attempts still count.</p>
          </div>
          #{error_html}
          #{quota_html}
          <form id="record-form" action="/chat" method="post" enctype="multipart/form-data">
            #{token_html}
            <input id="audio" type="file" name="audio" accept="audio/*" required>
            <label for="language">Whisper language hint</label>
            <select id="language" name="language">#{language_options(language)}</select>
            <label for="speaker">Aura speaker</label>
            <select id="speaker" name="speaker">#{speaker_options(speaker)}</select>
            <button id="record-button" class="record-button" type="button" data-state="idle" aria-describedby="record-status">
              <span class="record-icon">#{microphone_icon}</span>
              <span class="record-label">Start recording</span>
            </button>
            <p id="record-status" class="status" role="status" aria-live="polite">Tap the mic, speak, then tap it again to send the recording.</p>
            <button class="sr-only" type="submit">Submit recording</button>
            <noscript><p class="error">This demo needs JavaScript-enabled microphone recording.</p></noscript>
          </form>
        </section>
        #{transcript_html}
        #{reply_html}
        #{spoken_script_html}
      </main>
      <script>
        (() => {
          const form = document.getElementById('record-form');
          const audioInput = document.getElementById('audio');
          const recordButton = document.getElementById('record-button');
          const recordLabel = recordButton?.querySelector('.record-label');
          const status = document.getElementById('record-status');

          const setStatus = (state, message) => {
            if (!recordButton || !recordLabel || !status) return;
            recordButton.dataset.state = state;
            recordButton.setAttribute('aria-pressed', state === 'recording' ? 'true' : 'false');
            recordLabel.textContent =
              state === 'recording' ? 'Stop and send' :
              state === 'processing' ? 'Uploading…' :
              'Start recording';
            status.textContent = message;
          };

          if (!form || !audioInput || !recordButton || !recordLabel || !status) return;
          if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder || !window.DataTransfer) {
            recordButton.disabled = true;
            setStatus('idle', 'This browser cannot record audio here.');
            return;
          }

          let stream = null;
          let recorder = null;
          let recording = false;
          let chunks = [];

          const pickMimeType = () => {
            const choices = [
              'audio/webm;codecs=opus',
              'audio/webm',
              'audio/mp4',
              'audio/ogg;codecs=opus',
              'audio/ogg'
            ];
            return choices.find((type) => !MediaRecorder.isTypeSupported || MediaRecorder.isTypeSupported(type)) || '';
          };

          const extensionFor = (mimeType) => {
            if (mimeType.includes('mp4') || mimeType.includes('aac') || mimeType.includes('mpeg')) return 'm4a';
            if (mimeType.includes('ogg')) return 'ogg';
            return 'webm';
          };

          const stopTracks = () => {
            if (!stream) return;
            for (const track of stream.getTracks()) track.stop();
            stream = null;
          };

          recordButton.addEventListener('click', async () => {
            if (recordButton.disabled) return;

            if (!recording) {
              try {
                stream = await navigator.mediaDevices.getUserMedia({ audio: true });
                chunks = [];
                const mimeType = pickMimeType();
                recorder = mimeType ? new MediaRecorder(stream, { mimeType }) : new MediaRecorder(stream);
                recorder.addEventListener('dataavailable', (event) => {
                  if (event.data && event.data.size > 0) chunks.push(event.data);
                });
                recorder.addEventListener('stop', () => {
                  const mimeType = recorder?.mimeType || 'audio/webm';
                  const blob = new Blob(chunks, { type: mimeType });
                  const file = new File([blob], `browser-recording.${extensionFor(mimeType)}`, { type: mimeType });
                  const transfer = new DataTransfer();
                  transfer.items.add(file);
                  audioInput.files = transfer.files;
                  stopTracks();
                  setStatus('processing', 'Uploading your recording…');
                  recordButton.disabled = true;
                  if (form.requestSubmit) form.requestSubmit();
                  else form.submit();
                });
                recorder.start();
                recording = true;
                setStatus('recording', 'Recording… tap again when you are done.');
              } catch (error) {
                stopTracks();
                setStatus('idle', 'Microphone access failed. Allow the mic and try again.');
              }
              return;
            }

            if (recorder) {
              recording = false;
              recorder.stop();
            }
          });
        })();
      </script>
    </body>
    </html>
  HTML
end

def ensure_audio!(uploaded)
  unless uploaded.respond_to?(:to_uint8_array)
    raise ArgumentError, "Choose an audio file first."
  end

  raise ArgumentError, "Audio file is empty." if uploaded.size.zero?
  if uploaded.size > MAX_AUDIO_BYTES
    raise ArgumentError, "Audio file must be 5 MB or smaller."
  end

  uploaded
end

def reply_prompt(transcript)
  <<~TEXT
    The user sent this speech transcript:
    #{transcript}

    Reply directly to the user in one short answer.
  TEXT
end

def romaji_prompt(reply)
  <<~TEXT
    Rewrite this Japanese reply into simple romaji for speech playback.

    Rules:
    - keep the meaning in Japanese
    - use lowercase ascii only
    - use spaces between words when helpful
    - keep punctuation simple
    - output only the romaji text

    Reply:
    #{reply}
  TEXT
end

def contains_japanese?(text)
  !!(text.to_s =~ /[ぁ-んァ-ヶ一-龠々ー]/)
end

def spoken_script_for(reply)
  script = reply.to_s.strip
  return script unless contains_japanese?(script)

  romaji = ai
    .chat_text(
      romaji_prompt(script),
      model: CHAT_MODEL,
      system: ROMAJI_SYSTEM_PROMPT,
      max_tokens: 240
    )
    .to_s
    .gsub(/\s+/, " ")
    .strip
    .downcase
  if romaji.empty?
    raise(
      Cloudflare::AIError.new(
        "Kimi returned an empty romaji script for speech synthesis.",
        model: CHAT_MODEL,
        operation: "romanize_for_tts"
      )
    )
  end

  unless /\A[\x20-\x7E]+\z/.match?(romaji) && /[a-z]/.match?(romaji)
    raise(
      Cloudflare::AIError.new(
        "Kimi returned non-ASCII output for romaji speech synthesis.",
        model: CHAT_MODEL,
        operation: "romanize_for_tts"
      )
    )
  end

  romaji
end

def transcribe_text_from(audio, language)
  current = normalize_language(language)
  return ai.transcribe_text(audio).to_s.strip if current == "auto"
  ai.transcribe_text(audio, language: current).to_s.strip
end

def current_utc_day
  Time.now.utc.strftime("%Y-%m-%d")
end

def voice_limit_response(path)
  stub = durable_object("voice_limit", VOICE_LIMIT_DO_NAME)
  if stub.nil?
    raise(
      VoiceChatConfigError,
      "VOICE_LIMIT binding missing (configure [[durable_objects.bindings]])."
    )
  end

  response = stub.fetch(
    "https://voice-limit.internal#{path}",
    method: "POST",
    headers: {
      "content-type" => "application/json"
    },
    body: {day: current_utc_day, limit: voice_chat_daily_limit}.to_json
  )
  payload = response.body.empty? ? {} : JSON.parse(response.body)
  return payload if response.ok? || response.status == 429

  message = payload["error"].to_s
  message = "Voice usage limit check failed." if message.empty?
  raise VoiceChatConfigError, message
end

def voice_limit_status
  voice_limit_response("/peek")
end

def reserve_voice_limit!
  payload = voice_limit_response("/reserve")
  return payload if payload["allowed"]

  raise(
    VoiceChatDailyLimitError.new(
      "Daily voice limit reached (#{payload["count"]}/#{payload["limit"]}).",
      remaining: payload["remaining"]
    )
  )
end

def access_failure
  secret = voice_chat_token
  return nil if secret.empty? && dev_host?
  if secret.empty?
    return [
      503,
      "VOICE_CHAT_TOKEN secret missing. Set it with `wrangler secret put VOICE_CHAT_TOKEN`."
    ]
  end

  return nil if Rack::Utils.secure_compare(secret, params["token"].to_s)

  [404, "Not found"]
end

get("/") do
  if (failure = access_failure)
    status(failure[0])
    content_type("text/plain; charset=utf-8")
    next failure[1]
  end

  content_type("text/html; charset=utf-8")
  usage = voice_limit_status
  page(token: params["token"], daily_remaining: usage["remaining"])
rescue VoiceChatConfigError => e
  status(503)
  content_type("text/plain; charset=utf-8")
  e.message
end

post("/chat") do
  if (failure = access_failure)
    status(failure[0])
    content_type("text/plain; charset=utf-8")
    next failure[1]
  end

  content_type("text/html; charset=utf-8")
  usage = reserve_voice_limit!
  audio = ensure_audio!(params["audio"])
  speaker = normalize_speaker(params["speaker"])
  language = normalize_language(params["language"])
  transcript = transcribe_text_from(audio, language)
  if transcript.empty?
    status(502)
    next (page(
      speaker: speaker,
      language: language,
      token: params["token"],
      daily_remaining: usage["remaining"],
      error: "Whisper returned an empty transcript."
    ))
  end

  reply = ai
    .chat_text(
      reply_prompt(transcript),
      model: CHAT_MODEL,
      system: SYSTEM_PROMPT,
      max_tokens: 200
    )
    .to_s
    .strip[
    0,
    MAX_REPLY_CHARS
  ]
  reply = "The model returned an empty reply." if reply.empty?
  spoken_script = spoken_script_for(reply)
  audio_src = ai.speak_data_url(spoken_script, speaker: speaker, encoding: "mp3").to_s

  page(
    transcript: transcript,
    reply: reply,
    spoken_script: spoken_script,
    audio_src: audio_src,
    speaker: speaker,
    language: language,
    token: params["token"],
    daily_remaining: usage["remaining"]
  )
rescue ArgumentError => e
  status(422)
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    error: e.message
  )
rescue VoiceChatDailyLimitError => e
  status(429)
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    daily_remaining: e.remaining,
    error: e.message
  )
rescue VoiceChatConfigError => e
  status(503)
  content_type("text/plain; charset=utf-8")
  e.message
rescue Cloudflare::AIError => e
  status(502)
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    daily_remaining: usage && usage["remaining"],
    error: e.message
  )
end
