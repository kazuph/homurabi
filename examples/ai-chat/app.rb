# frozen_string_literal: true

require "sinatra"

MODEL = "@cf/moonshotai/kimi-k2.6"
SYSTEM_PROMPT = "You are a helpful assistant. Reply clearly and keep the answer under 280 characters.".freeze
MAX_PROMPT_CHARS = 600
MAX_REPLY_CHARS = 280

def h(text)
  Rack::Utils.escape_html(text.to_s)
end

def page(prompt: "", reply: nil, error: nil)
  error_html = error ? "<p class=\"error\" role=\"alert\">#{h(error)}</p>" : ""
  reply_html = reply ? "<section><h2>Reply</h2><pre>#{h(reply)}</pre></section>" : ""

  <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>ai-chat</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1rem 3rem; line-height: 1.5; }
        h1 { margin-bottom: .2rem; }
        p.note { color: #666; margin-top: 0; }
        form, section { background: rgba(127, 127, 127, .08); border-radius: 1rem; padding: 1rem; margin-top: 1rem; }
        label { display: block; font-weight: 600; margin-bottom: .5rem; }
        textarea { width: 100%; min-height: 9rem; box-sizing: border-box; padding: .8rem; font: inherit; }
        button { margin-top: .8rem; padding: .7rem 1rem; font: inherit; cursor: pointer; }
        pre { white-space: pre-wrap; margin: 0; font: inherit; }
        .error { color: #b00020; font-weight: 600; }
      </style>
    </head>
    <body>
      <h1>ai-chat</h1>
      <p class="note">The smallest possible Kimi K2.6 example: one form, one Workers AI call, one reply.</p>
      #{error_html}
      <form action="/chat" method="post">
        <label for="prompt">Message</label>
        <textarea id="prompt" name="prompt" maxlength="#{MAX_PROMPT_CHARS}" placeholder="Ask something..." required>#{h(prompt)}</textarea>
        <button type="submit">Send to Kimi</button>
      </form>
      #{reply_html}
    </body>
    </html>
  HTML
end

get("/") do
  content_type("text/html; charset=utf-8")
  page
end

post("/chat") do
  content_type("text/html; charset=utf-8")
  prompt = params["prompt"].to_s.strip[0, MAX_PROMPT_CHARS]
  if prompt.empty?
    status(422)
    next page(prompt: prompt, error: "Enter a message first.")
  end

  reply = ai
    .chat_text(prompt, model: MODEL, system: SYSTEM_PROMPT, max_tokens: 200)
    .to_s
    .strip[
    0,
    MAX_REPLY_CHARS
  ]
  reply = "The model returned an empty reply." if reply.empty?

  page(prompt: prompt, reply: reply)
rescue Cloudflare::AIError => e
  status(502)
  page(prompt: prompt, error: e.message)
end
