# frozen_string_literal: true

require "json"
require "sinatra"

CHAT_MODEL = "@cf/moonshotai/kimi-k2.6"
SYSTEM_PROMPT =
  "You are a helpful assistant. Reply to the spoken message clearly and keep the answer under 280 characters.".freeze
ROMAJI_SYSTEM_PROMPT =
  "You rewrite Japanese text into simple romaji for text-to-speech. Return only lowercase ASCII romaji with spaces and basic punctuation. Do not translate into English, do not explain, and do not use kana, kanji, markdown, or code fences.".freeze
MAX_AUDIO_BYTES = 5 * 1024 * 1024
MAX_REPLY_CHARS = 280
DEFAULT_DAILY_LIMIT = 20
LANGUAGES = {
  "auto" => "Auto detect",
  "en" => "English",
  "ja" => "Japanese"
}.freeze
SPEAKERS = { "luna" => "Luna", "stella" => "Stella", "orion" => "Orion" }.freeze
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
  headers = { "content-type" => "application/json" }

  if day.empty? || !limit.positive?
    next 400, headers, { "error" => "day and limit are required" }.to_json
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
        base.merge(
          "count" => next_count,
          "remaining" => [limit - next_count, 0].max,
          "allowed" => true
        ).to_json
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
      %(<option value="#{h(value)}"#{selected_attr}>#{h(label)}</option>)
    end
    .join
end

def speaker_options(selected)
  current = normalize_speaker(selected)
  SPEAKERS
    .map do |value, label|
      selected_attr = value == current ? " selected" : ""
      %(<option value="#{h(value)}"#{selected_attr}>#{h(label)}</option>)
    end
    .join
end

def page(
  filename: nil,
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
  error_html = error ? %(<p class="error" role="alert">#{h(error)}</p>) : ""
  token_html =
    if token.to_s.empty?
      ""
    else
      %(<input type="hidden" name="token" value="#{h(token)}">)
    end
  quota_html =
    if daily_remaining.nil?
      ""
    else
      %(<p class="meta"><strong>Daily attempts remaining:</strong> #{h(daily_remaining)}</p>)
    end
  filename_html =
    (
      if filename
        %(<p class="meta"><strong>Audio file:</strong> #{h(filename)}</p>)
      else
        ""
      end
    )
  transcript_html =
    (
      if transcript
        %(<section><h2>Transcript</h2><pre>#{h(transcript)}</pre></section>)
      else
        ""
      end
    )
  spoken_script_html =
    (
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
  reply_html =
    if reply
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
        :root { color-scheme: light dark; }
        body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1rem 3rem; line-height: 1.5; }
        h1 { margin-bottom: .2rem; }
        p.note, p.meta { color: #666; margin-top: 0; }
        form, section { background: rgba(127, 127, 127, .08); border-radius: 1rem; padding: 1rem; margin-top: 1rem; }
        label { display: block; font-weight: 600; margin-bottom: .5rem; }
        input[type=file], select { display: block; width: 100%; box-sizing: border-box; padding: .7rem; margin-bottom: .8rem; font: inherit; }
        button { padding: .7rem 1rem; font: inherit; cursor: pointer; }
        pre { white-space: pre-wrap; margin: 0 0 1rem; font: inherit; }
        audio { width: 100%; }
        .error { color: #b00020; font-weight: 600; }
      </style>
    </head>
    <body>
      <h1>ai-voice-chat</h1>
      <p class="note">Upload one audio clip, transcribe it, answer it, then let Aura read the answer back.</p>
      <p class="note">When Kimi replies in Japanese, the app rewrites the answer into romaji before sending it to Aura.</p>
      <p class="note">The daily cap is consumed before any AI call runs, so failed attempts still count. This is intentional to cap spend.</p>
      #{error_html}
      #{quota_html}
      <form action="/chat" method="post" enctype="multipart/form-data">
        #{token_html}
        <label for="audio">Audio clip</label>
        <input id="audio" type="file" name="audio" accept="audio/*" capture required>
        <label for="language">Whisper language hint</label>
        <select id="language" name="language">#{language_options(language)}</select>
        <label for="speaker">Aura speaker</label>
        <select id="speaker" name="speaker">#{speaker_options(speaker)}</select>
        <button type="submit">Transcribe, reply, and speak</button>
      </form>
      #{filename_html}
      #{transcript_html}
      #{reply_html}
      #{spoken_script_html}
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

  romaji =
    ai
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
    raise VoiceChatConfigError,
          "VOICE_LIMIT binding missing (configure [[durable_objects.bindings]])."
  end

  response =
    stub.fetch(
      "https://voice-limit.internal#{path}",
      method: "POST",
      headers: {
        "content-type" => "application/json"
      },
      body: { day: current_utc_day, limit: voice_chat_daily_limit }.to_json
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

get "/" do
  if (failure = access_failure)
    status failure[0]
    content_type "text/plain; charset=utf-8"
    next failure[1]
  end
  content_type "text/html; charset=utf-8"
  usage = voice_limit_status
  page(token: params["token"], daily_remaining: usage["remaining"])
rescue VoiceChatConfigError => e
  status 503
  content_type "text/plain; charset=utf-8"
  e.message
end

post "/chat" do
  if (failure = access_failure)
    status failure[0]
    content_type "text/plain; charset=utf-8"
    next failure[1]
  end
  content_type "text/html; charset=utf-8"
  usage = reserve_voice_limit!
  audio = ensure_audio!(params["audio"])
  speaker = normalize_speaker(params["speaker"])
  language = normalize_language(params["language"])
  transcript = transcribe_text_from(audio, language)
  if transcript.empty?
    status 502
    next(
      page(
        filename: audio.filename,
        speaker: speaker,
        language: language,
        token: params["token"],
        daily_remaining: usage["remaining"],
        error: "Whisper returned an empty transcript."
      )
    )
  end

  reply =
    ai
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
  audio_src =
    ai.speak_data_url(spoken_script, speaker: speaker, encoding: "mp3").to_s

  page(
    filename: audio.filename,
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
  status 422
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    error: e.message
  )
rescue VoiceChatDailyLimitError => e
  status 429
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    daily_remaining: e.remaining,
    error: e.message
  )
rescue VoiceChatConfigError => e
  status 503
  content_type "text/plain; charset=utf-8"
  e.message
rescue Cloudflare::AIError => e
  status 502
  page(
    speaker: params["speaker"],
    language: params["language"],
    token: params["token"],
    daily_remaining: usage && usage["remaining"],
    error: e.message
  )
end
