# frozen_string_literal: true
# backtick_javascript: true
#
# Phase 11A — multipart/form-data receive pipeline.
#
# Why a bespoke parser instead of Rack::Multipart::Parser?
#
# Rack's parser does work on Opal in principle (strscan is in stdlib),
# but it relies on Tempfile — which is a stub on Workers since there is
# no writable filesystem. It also assumes the request body is a true
# binary ByteString, whereas on Workers we have to cross the JS/Ruby
# boundary and Opal Strings are JS Strings (UTF-16 code units). The
# correct way to pass bytes through that boundary is to encode each
# byte as a single `char code 0-255` latin1 character, then `unescape
# / String.fromCharCode.apply` back into a Uint8Array when we need
# raw bytes again (e.g. R2.put).
#
# This module exposes:
#
#   Cloudflare::Multipart.parse(body_binstr, content_type)
#     → Hash[String => Cloudflare::UploadedFile | String]
#
#   Cloudflare::UploadedFile
#     #filename      — original filename from the Content-Disposition header
#     #content_type  — part Content-Type (defaults to application/octet-stream)
#     #name          — form field name
#     #size          — byte length
#     #bytes_binstr  — the latin1-encoded byte string (1 char = 1 byte)
#     #to_uint8_array — JS Uint8Array suitable for fetch body / R2.put
#     #read          — returns bytes_binstr, mirroring Tempfile#read
#     #rewind        — no-op (content is fully in-memory, there is no
#                       writable filesystem on Workers)
#
# Also installs `Rack::Request#post?`-path hook: when the Sinatra route
# calls `params['file']`, `Rack::Request#POST` delegates to
# `Cloudflare::Multipart.rack_params(env)` which parses once, caches on
# the env, and hydrates `params` with UploadedFile / String values.

module Cloudflare
  # Struct-ish wrapper for an uploaded file part. Identical shape to
  # the `{:filename, :type, :name, :tempfile, :head}` Hash Rack's
  # parser returns, plus extras for the Workers use case.
  class UploadedFile
    attr_reader :filename, :content_type, :name, :head, :bytes_binstr

    def initialize(filename:, content_type:, name:, head: '', bytes_binstr: '')
      @filename = filename
      @content_type = content_type || 'application/octet-stream'
      @name = name
      @head = head
      @bytes_binstr = bytes_binstr || ''
    end

    # Byte length of the part (not the JS string length — they're the
    # same here because we use latin1 1-byte-per-char encoding).
    def size
      @bytes_binstr.length
    end
    alias_method :bytesize, :size

    # Convenience accessor matching the CRuby Rack shape.
    def type
      @content_type
    end

    # Read the full byte string. Mirrors Tempfile#read.
    def read
      @bytes_binstr
    end

    def rewind
      self
    end

    def close
      self
    end

    # Convert the latin1 byte-string to a real JS Uint8Array. Used to
    # feed raw bytes to `env.BUCKET.put`, `globalThis.fetch(body: ...)`,
    # `Blob`, etc. without re-encoding through UTF-8.
    #
    # NOTE: single-line backtick x-string so Opal emits it as an
    # expression (multi-line x-strings compile to raw statements and
    # would silently return `undefined`). Same gotcha documented
    # elsewhere in this codebase (see lib/cloudflare_workers.rb).
    def to_uint8_array
      `(function(s) { var len = s.length; var out = new Uint8Array(len); for (var i = 0; i < len; i++) { out[i] = s.charCodeAt(i) & 0xff; } return out; })(#{@bytes_binstr})`
    end

    # Convert to a JS Blob for fetch/Response bodies.
    def to_blob
      u8 = to_uint8_array
      ct = @content_type
      `new Blob([#{u8}], { type: #{ct} })`
    end

    # Rack-friendly Hash view. Match the exact shape Rack::Multipart
    # produces so gems that do `params['file'][:filename]` keep working.
    def to_h
      {
        filename: @filename,
        type:     @content_type,
        name:     @name,
        head:     @head,
        tempfile: self
      }
    end
    alias_method :to_hash, :to_h

    # `#[]` so `file[:filename]` works on the UploadedFile itself
    # (some gems use the Hash shape, some grab the file object —
    # support both access patterns to reduce downstream surprises).
    def [](key)
      to_h[key.to_sym]
    end
  end

  module Multipart
    CRLF = "\r\n"

    # Extract the multipart boundary from a Content-Type header.
    # Matches `boundary=AaB03x`, `boundary="weird boundary"`,
    # and whitespace/case variants. Quoted forms are preserved as-is
    # so `boundary="foo bar"` → `foo bar` (internal whitespace kept),
    # while unquoted forms stop at the next delimiter.
    def self.parse_boundary(content_type)
      return nil if content_type.nil?
      ct = content_type.to_s
      return nil unless ct.downcase.include?('multipart/')
      # Prefer the quoted form. The quoted value may contain any byte
      # except a literal `"` (RFC 2046 §5.1.1 bans `"` in the value).
      if (m = ct.match(/boundary="([^"]+)"/i))
        return m[1]
      end
      if (m = ct.match(/boundary=([^;,\s]+)/i))
        return m[1]
      end
      nil
    end

    # Parse a multipart/form-data payload.
    #
    # @param body_binstr [String] latin1 byte string (1 char = 1 byte)
    # @param content_type [String] the request Content-Type header
    # @return [Hash] keys are form-field names (strings); values are
    #   either UploadedFile (for file parts) or String (for plain
    #   text fields).
    def self.parse(body_binstr, content_type)
      boundary = parse_boundary(content_type)
      return {} if boundary.nil?
      return {} if body_binstr.nil? || body_binstr.empty?

      sep       = '--' + boundary
      term      = '--' + boundary + '--'
      sep_line  = sep + CRLF
      sep_last  = sep + CRLF  # the very first boundary may skip the leading CRLF
      body      = body_binstr.to_s

      # Skip any preamble before the first boundary.
      start_idx = body.index(sep)
      return {} if start_idx.nil?
      cursor = start_idx + sep.length
      # consume possible CRLF right after the first boundary
      if body[cursor, 2] == CRLF
        cursor += 2
      end

      parts = {}

      loop do
        # Find the next boundary after cursor.
        # Each part ends with CRLF before the next "--boundary" line,
        # or "--boundary--" for the terminator.
        next_sep = body.index(CRLF + sep, cursor)
        break if next_sep.nil?

        part = body[cursor...next_sep]

        # Split headers / body on the first blank line (CRLF CRLF).
        headers_end = part.index(CRLF + CRLF)
        if headers_end
          raw_headers = part[0...headers_end]
          raw_body    = part[(headers_end + 4)..-1] || ''
        else
          raw_headers = part
          raw_body    = ''
        end

        disposition = nil
        ctype       = nil
        raw_headers.split(CRLF).each do |line|
          name, value = line.split(':', 2)
          next if name.nil? || value.nil?
          name = name.strip.downcase
          value = value.strip
          case name
          when 'content-disposition' then disposition = value
          when 'content-type'        then ctype = value
          end
        end

        if disposition
          field_name = extract_disposition_param(disposition, 'name')
          filename   = extract_disposition_param(disposition, 'filename')
          if field_name
            if filename && !filename.empty?
              parts[field_name] = UploadedFile.new(
                name: field_name,
                filename: filename,
                content_type: ctype,
                head: raw_headers,
                bytes_binstr: raw_body
              )
            else
              parts[field_name] = raw_body
            end
          end
        end

        cursor = next_sep + CRLF.length + sep.length
        # Check whether this is the terminator `--boundary--`
        if body[cursor, 2] == '--'
          break
        end
        if body[cursor, 2] == CRLF
          cursor += 2
        end
      end

      parts
    end

    # Extract a quoted or bare parameter from a Content-Disposition value.
    # Handles `name="file"; filename="pic.png"` and RFC 5987
    # `filename*=UTF-8''pic.png` (best-effort URL decoding).
    #
    # The `(^|[;\s])` prefix is load-bearing: without it, looking up
    # `name` would also match inside `filename*=...` (substring "name*=")
    # and mis-attribute the filename to the form-field name. RFC 7578
    # places each parameter after `;` (with optional whitespace), so the
    # prefix is free.
    def self.extract_disposition_param(disposition, key)
      k = Regexp.escape(key)
      # filename*=charset'lang'encoded  (RFC 5987)
      star_re = /(?:^|[;\s])#{k}\*\s*=\s*([^;]+)/i
      if (m = disposition.match(star_re))
        raw = m[1].strip
        parts = raw.split("'", 3)
        encoded = parts[2] || parts[0]
        return decode_rfc5987(encoded)
      end
      # Quoted `key="value"`
      q_re = /(?:^|[;\s])#{k}\s*=\s*"((?:\\"|[^"])*)"/i
      if (m = disposition.match(q_re))
        return m[1].gsub('\\"', '"')
      end
      # Bare `key=value`
      b_re = /(?:^|[;\s])#{k}\s*=\s*([^;]+)/i
      if (m = disposition.match(b_re))
        return m[1].strip
      end
      nil
    end

    def self.decode_rfc5987(s)
      `decodeURIComponent(#{s.to_s})`
    rescue StandardError
      s
    end

    # Rack::Request integration — parse the multipart body once per
    # request, cache on the env, hydrate Sinatra's `params` Hash.
    #
    # Called lazily from our patched Rack::Request#POST.
    def self.rack_params(env)
      cached = env['cloudflare.multipart']
      return cached if cached

      ct = env['CONTENT_TYPE']
      return ({}) unless ct && ct.to_s.downcase.include?('multipart/')

      io = env['rack.input']
      return ({}) if io.nil?

      # `rack.input` is normally a StringIO wrapping the body_binstr
      # we staged in src/worker.mjs. Read the full body; it's already
      # resolved server-side (Workers doesn't stream request bodies
      # back into Opal).
      if io.respond_to?(:rewind)
        begin
          io.rewind
        rescue
          # some stubs don't support rewind — ignore
        end
      end
      body = io.respond_to?(:read) ? io.read.to_s : ''

      parsed = parse(body, ct)
      env['cloudflare.multipart'] = parsed
      parsed
    end
  end
end

# --------------------------------------------------------------------
# Rack::Request hook — expose multipart parts via `params[name]`.
# --------------------------------------------------------------------
#
# Sinatra's `params` is the result of `Rack::Request#params`, which
# merges GET + POST data. `#POST` on the upstream Rack gem uses
# `Rack::Multipart.extract_multipart` — which fails on Workers (no
# Tempfile). We reopen Rack::Request and override #POST to use the
# bespoke Cloudflare::Multipart parser for multipart requests, falling
# back to the gem implementation for everything else.

require 'rack/request'

module Rack
  class Request
    alias_method :__homura_original_POST, :POST unless method_defined?(:__homura_original_POST)

    def POST
      ct = env['CONTENT_TYPE']
      if ct && ct.to_s.downcase.include?('multipart/')
        ::Cloudflare::Multipart.rack_params(env)
      else
        __homura_original_POST
      end
    end
  end
end
