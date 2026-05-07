# frozen_string_literal: true

require "sinatra"

CHAT_MODEL = "@cf/moonshotai/kimi-k2.6"
SYSTEM_PROMPT = "You are a helpful assistant. Reply to the spoken message clearly and keep the answer under 280 characters."
  .freeze
MAX_AUDIO_BYTES = 5 * 1024 * 1024
MAX_REPLY_CHARS = 280
LANGUAGES = {
  "auto" => "Auto detect",
  "en" => "English",
  "ja" => "Japanese"
}.freeze

def h(text)
  Rack::Utils.escape_html(text.to_s)
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

def microphone_icon
  <<~SVG
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M12 18.75a6 6 0 0 0 6-6v-1.5m-6 7.5a6 6 0 0 1-6-6v-1.5m6 7.5v4.5m0 0H8.25m3.75 0h3.75M12 15.75A3 3 0 0 1 9 12.75V6a3 3 0 1 1 6 0v6.75a3 3 0 0 1-3 3Z"/>
    </svg>
  SVG
end

def page(transcript: nil, reply: nil, language: "auto", error: nil)
  error_html = error ? "<p class=\"error\" role=\"alert\">#{h(error)}</p>" : ""
  transcript_html = (
    if transcript
      "<section><h2>Transcript</h2><pre>#{h(transcript)}</pre></section>"
    else
      ""
    end
  )
  reply_html = reply ? "<section><h2>Kimi reply</h2><pre>#{h(reply)}</pre></section>" : ""

  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>ai-transcribe-chat</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #09070e;
          --panel: rgba(20, 18, 29, .82);
          --panel-edge: rgba(255, 255, 255, .08);
          --text: #f5efe6;
          --muted: #c4b9aa;
          --accent: #ff6b6b;
          --accent-strong: #ff3b30;
          --accent-soft: rgba(255, 99, 99, .18);
          --focus: #ffd166;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          font-family: "Avenir Next", "Hiragino Sans", sans-serif;
          line-height: 1.5;
          color: var(--text);
          background:
            radial-gradient(circle at top, rgba(255, 107, 107, .24), transparent 30rem),
            radial-gradient(circle at bottom right, rgba(255, 209, 102, .16), transparent 24rem),
            linear-gradient(180deg, #120e19, var(--bg));
        }
        main { max-width: 52rem; margin: 0 auto; padding: 2.5rem 1rem 4rem; }
        h1 {
          margin: 0;
          font-size: clamp(2.8rem, 8vw, 5rem);
          line-height: .95;
          letter-spacing: -.05em;
        }
        p.note, p.status, p.meta { color: var(--muted); }
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
        .hero-copy { max-width: 36rem; }
        .hero-copy p { margin: .85rem 0 0; }
        form { margin-top: 1.25rem; }
        label {
          display: block;
          margin-bottom: .5rem;
          font-size: .94rem;
          font-weight: 700;
          letter-spacing: .04em;
          text-transform: uppercase;
          color: #fff2de;
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
          width: min(100%, 18rem);
          aspect-ratio: 1;
          margin: 1.4rem auto .8rem;
          border: 0;
          border-radius: 50%;
          cursor: pointer;
          color: inherit;
          background:
            radial-gradient(circle at 35% 30%, #ffb3b3, transparent 28%),
            radial-gradient(circle at center, var(--accent), var(--accent-strong) 72%);
          box-shadow:
            0 0 0 1px rgba(255, 255, 255, .1),
            0 28px 50px rgba(255, 59, 48, .32),
            0 0 0 18px var(--accent-soft);
          transition: transform .18s ease, box-shadow .18s ease, filter .18s ease;
        }
        .record-button:hover { transform: translateY(-2px) scale(1.01); }
        .record-button[data-state="recording"] {
          animation: pulse 1.4s ease-in-out infinite;
          box-shadow:
            0 0 0 1px rgba(255, 255, 255, .12),
            0 0 0 20px rgba(255, 59, 48, .16),
            0 0 0 40px rgba(255, 59, 48, .08);
        }
        .record-button[disabled] {
          cursor: progress;
          filter: grayscale(.2);
          opacity: .82;
        }
        .record-icon {
          display: grid;
          place-items: center;
          width: 4.4rem;
          height: 4.4rem;
          border-radius: 999px;
          background: rgba(255, 255, 255, .94);
          color: var(--accent-strong);
          box-shadow:
            inset 0 0 0 1px rgba(255, 255, 255, .32),
            0 12px 24px rgba(0, 0, 0, .16);
        }
        .record-icon svg {
          width: 2.5rem;
          height: 2.5rem;
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
          color: #fff2de;
        }
        pre {
          margin: 0;
          white-space: pre-wrap;
          font: inherit;
        }
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
            <h1>Speak into the mic.</h1>
            <p class="note">This demo records in the browser, sends the captured clip to Whisper, then asks Kimi K2.6 to answer the transcript.</p>
          </div>
          #{error_html}
          <form id="record-form" action="/chat" method="post" enctype="multipart/form-data">
            <input id="audio" type="file" name="audio" accept="audio/*" required>
            <label for="language">Whisper language hint</label>
            <select id="language" name="language">#{language_options(language)}</select>
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

def transcribe_text_from(audio, language)
  current = normalize_language(language)
  return ai.transcribe_text(audio).to_s.strip if current == "auto"
  ai.transcribe_text(audio, language: current).to_s.strip
end

get("/") do
  content_type("text/html; charset=utf-8")
  page
end

post("/chat") do
  content_type("text/html; charset=utf-8")
  audio = ensure_audio!(params["audio"])
  language = normalize_language(params["language"])
  transcript = transcribe_text_from(audio, language)
  if transcript.empty?
    status(502)
    next (page(language: language, error: "Whisper returned an empty transcript."))
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

  page(transcript: transcript, reply: reply, language: language)
rescue ArgumentError => e
  status(422)
  page(language: params["language"], error: e.message)
rescue Cloudflare::AIError => e
  status(502)
  page(language: params["language"], error: e.message)
end
