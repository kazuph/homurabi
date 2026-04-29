# frozen_string_literal: true
#
# Phase 11B follow-up — Ruby-side Markdown to HTML converter.
#
# Purpose: render Workers AI chat replies that contain Markdown
# (`**bold**`, bullet lists, `` `inline code` ``, fenced code blocks,
# headings, links) as HTML on the server BEFORE they reach the client.
# The client then inserts the HTML via `innerHTML` instead of
# `textContent`.
#
# Why pure Ruby (not kramdown, not marked.js):
#   - kramdown is ~5k lines of Ruby and drags in `strscan` / `rexml`
#     / REXML dependencies that bloat the Opal bundle. The full
#     feature surface is overkill for chat replies.
#   - marked.js on the client is an option, but the project's stated
#     policy (README §Applied patches) prefers server-side Ruby
#     processing when the footprint is small enough to write in-house.
#   - A ~200-line focused parser covers the subset Gemma / gpt-oss
#     actually produce (bold, italic, code, lists, links, headings,
#     paragraphs) and is easy to audit for XSS (inputs are
#     HTML-escaped first, transforms ONLY emit known-safe tags).
#
# Security posture — IMPORTANT:
#   1. Every raw input is run through `Rack::Utils.escape_html` FIRST.
#      This turns `<script>` into `&lt;script&gt;` before any
#      Markdown rules fire, so an attacker cannot inject HTML by
#      embedding angle brackets in the Markdown source.
#   2. The `a` tag is the only tag that takes a URL. URLs are
#      validated against an http/https/mailto allowlist; anything
#      else (including `javascript:`, `data:`, etc.) is rendered as
#      literal text.
#   3. The output is suitable for injection via `innerHTML` as long
#      as steps 1 + 2 held.
#
# Scope — what we DO NOT support (out of scope for chat bubbles):
#   - Tables, task lists, footnotes, emojis via `:name:`
#   - HTML passthrough (the escape in step 1 deliberately disables it)
#   - Reference-style links
#   - Setext-style headings (=== / ---)
#   - Nested lists — bullets render flat for simplicity. If a model
#     replies with nested bullets the indentation is preserved as
#     text in the `<li>` but no `<ul>` is nested.
#
# Interface:
#
#   html = HomuraMarkdown.render(markdown_source)
#
#   Returns a String of HTML. Safe to assign to `innerHTML`.

require 'rack/utils'

module HomuraMarkdown
  # Main entry point.
  def self.render(source)
    return '' if source.nil? || source.to_s.empty?
    new_parser(source.to_s).render
  end

  def self.new_parser(src)
    Parser.new(src)
  end

  # URL allowlist for `[text](url)` links. Anything outside this set
  # is rendered as the literal bracketed text (no anchor) to prevent
  # `javascript:` / `data:` / untrusted-scheme injection.
  URL_ALLOW = %r{\A(?:https?://|mailto:|/|\#|\.\./|\./)}.freeze

  class Parser
    def initialize(src)
      # Normalise line endings and strip trailing whitespace per line.
      @lines = src.to_s.gsub("\r\n", "\n").gsub("\r", "\n").split("\n", -1)
      @out = []
      @i = 0
    end

    def render
      while @i < @lines.length
        line = @lines[@i]

        if (m = line.match(/\A```(\S*)\s*\z/))
          handle_fenced_code(m[1])
        elsif (m = line.match(/\A([#]{1,6})\s+(.+?)\s*\z/))
          level = m[1].length
          @out << "<h#{level}>#{inline(m[2])}</h#{level}>"
          @i += 1
        elsif line.match?(/\A\s*[-*+]\s+\S/)
          handle_unordered_list
        elsif line.match?(/\A\s*\d+\.\s+\S/)
          handle_ordered_list
        elsif line.strip.empty?
          @i += 1
        else
          handle_paragraph
        end
      end
      @out.join("\n")
    end

    private

    # ----- block handlers ---------------------------------------------

    # ``` fenced code block. Everything between the fences is
    # displayed verbatim (HTML-escaped, no inline processing).
    def handle_fenced_code(lang)
      @i += 1
      buf = []
      while @i < @lines.length
        line = @lines[@i]
        if line.match?(/\A```\s*\z/)
          @i += 1
          break
        end
        buf << line
        @i += 1
      end
      lang_attr = lang.nil? || lang.empty? ? '' : " class=\"language-#{Rack::Utils.escape_html(lang)}\""
      escaped = Rack::Utils.escape_html(buf.join("\n"))
      @out << "<pre><code#{lang_attr}>#{escaped}</code></pre>"
    end

    # - / * / + bullets. Consumes consecutive matching lines.
    def handle_unordered_list
      items = []
      while @i < @lines.length && (m = @lines[@i].match(/\A\s*[-*+]\s+(.+)\z/))
        items << m[1]
        @i += 1
      end
      @out << '<ul>' + items.map { |txt| "<li>#{inline(txt)}</li>" }.join + '</ul>'
    end

    # "1. foo" ordered list.
    def handle_ordered_list
      items = []
      while @i < @lines.length && (m = @lines[@i].match(/\A\s*\d+\.\s+(.+)\z/))
        items << m[1]
        @i += 1
      end
      @out << '<ol>' + items.map { |txt| "<li>#{inline(txt)}</li>" }.join + '</ol>'
    end

    # Paragraph: consumes lines until blank / block boundary.
    def handle_paragraph
      buf = []
      while @i < @lines.length
        line = @lines[@i]
        break if line.strip.empty?
        break if line.match?(/\A```/)
        break if line.match?(/\A[#]{1,6}\s+/)
        break if line.match?(/\A\s*[-*+]\s+\S/)
        break if line.match?(/\A\s*\d+\.\s+\S/)
        buf << line
        @i += 1
      end
      # "two-space trailing + newline" → <br>. Otherwise join with
      # a newline (which `white-space: pre-wrap` on the chat body
      # will render verbatim).
      joined = buf.map { |l| l.sub(/\s+\z/, '') }.join("\n")
      @out << "<p>#{inline(joined)}</p>"
    end

    # ----- inline (span-level) rendering ------------------------------

    # HTML-escape first, then apply ordered rules so the escape holds.
    # Each transform uses a tokenised placeholder pass so literal
    # characters inside code spans are not re-processed.
    def inline(text)
      t = Rack::Utils.escape_html(text)
      codes = []

      # 1. Inline code `...` → opaque tokens (so other rules skip).
      t = t.gsub(/`([^`]+?)`/) do
        codes << Regexp.last_match(1)
        "\x00CODE#{codes.length - 1}\x00"
      end

      # 2. Links [text](url). URL is checked against the allowlist;
      #    rejected urls fall back to "[text](url)" literal.
      t = t.gsub(/\[([^\]]+)\]\(([^)\s]+)\)/) do
        label = Regexp.last_match(1)
        url_raw = Regexp.last_match(2)
        # Escape already applied — `url_raw` is safe to put inside an
        # attribute value. Validate scheme via the ORIGINAL (pre-escape)
        # would be prettier but since HTML entities are a subset that
        # can't form a scheme, the regex still matches
        # "http://..." / "mailto:..." / "/..." correctly.
        if url_raw =~ URL_ALLOW
          "<a href=\"#{url_raw}\" target=\"_blank\" rel=\"noopener\">#{label}</a>"
        else
          "[#{label}](#{url_raw})"
        end
      end

      # 3. Bold — order matters: **strong** BEFORE *em* so a single
      #    pair of asterisks inside `**x**` doesn't greedily eat
      #    just one asterisk.
      t = t.gsub(/\*\*([^*\n]+?)\*\*/) { "<strong>#{Regexp.last_match(1)}</strong>" }
      t = t.gsub(/__([^_\n]+?)__/)     { "<strong>#{Regexp.last_match(1)}</strong>" }

      # 4. Italic — single `*...*` or `_..._`. Careful not to match
      #    inside already-emitted tags: the escape above turned `<`
      #    into `&lt;`, so `<strong>`/`</strong>` literal characters
      #    appear only after our own substitution and use `<` `>`
      #    (unescaped), which the italic regex never touches.
      t = t.gsub(/(?<![\w*])\*([^*\n]+?)\*(?![\w*])/) { "<em>#{Regexp.last_match(1)}</em>" }
      t = t.gsub(/(?<![\w_])_([^_\n]+?)_(?![\w_])/)   { "<em>#{Regexp.last_match(1)}</em>" }

      # 5. Restore code spans.
      codes.each_with_index do |c, i|
        t = t.sub("\x00CODE#{i}\x00", "<code>#{c}</code>")
      end

      t
    end
  end
end
