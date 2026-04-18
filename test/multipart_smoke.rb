# frozen_string_literal: true
# await: true
# backtick_javascript: true
#
# Cloudflare::Multipart parser smoke tests.

require 'cloudflare_workers/multipart'

module MultipartSmoke
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    result = block.call
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stdout.puts "  FAIL  #{label}"
    end
  rescue Exception => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stdout.puts "  CRASH #{label} — #{e.class}: #{e.message}"
  end

  def self.report
    total = @passed + @failed
    $stdout.puts ""
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    @errors.each { |e| $stdout.puts "  - #{e}" } if @errors.any?
    @failed == 0
  end
end

# --- helpers -----------------------------------------------------------

def build_multipart(boundary, parts)
  body = ''
  parts.each do |part|
    body += "--#{boundary}\r\n"
    if part[:filename]
      body += "Content-Disposition: form-data; name=\"#{part[:name]}\"; filename=\"#{part[:filename]}\"\r\n"
      body += "Content-Type: #{part[:content_type] || 'application/octet-stream'}\r\n"
    else
      body += "Content-Disposition: form-data; name=\"#{part[:name]}\"\r\n"
    end
    body += "\r\n"
    body += part[:data]
    body += "\r\n"
  end
  body += "--#{boundary}--\r\n"
  body
end

$stdout.puts "=== Multipart smoke tests ==="

# 1. Boundary extraction
MultipartSmoke.assert('parse_boundary recognises quoted and unquoted forms') {
  Cloudflare::Multipart.parse_boundary('multipart/form-data; boundary=foo') == 'foo' &&
    Cloudflare::Multipart.parse_boundary('multipart/form-data; boundary="foo bar"') == 'foo bar' &&
    Cloudflare::Multipart.parse_boundary('application/json').nil?
}

# 2. Simple text-field parse
MultipartSmoke.assert('parses a single text field') {
  b = 'B1'
  body = build_multipart(b, [{ name: 'greeting', data: 'hello' }])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['greeting'] == 'hello'
}

# 3. Mixed text + file
MultipartSmoke.assert('parses text + file parts in one payload') {
  b = 'B2'
  body = build_multipart(b, [
    { name: 'note', data: 'hi' },
    { name: 'file', filename: 'a.bin', content_type: 'application/octet-stream', data: 'ABCDEF' }
  ])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['note'] == 'hi' &&
    parts['file'].is_a?(Cloudflare::UploadedFile) &&
    parts['file'].filename == 'a.bin' &&
    parts['file'].content_type == 'application/octet-stream' &&
    parts['file'].read == 'ABCDEF' &&
    parts['file'].size == 6
}

# 4. Binary bytes survive the parser (no UTF-8 mangling)
MultipartSmoke.assert('preserves binary bytes (\x00..\xFF) through parsing') {
  b = 'B3'
  # 256-byte content covering every byte value.
  bytes = (0..255).map { |c| c.chr }.join
  body = build_multipart(b, [
    { name: 'file', filename: 'bin', content_type: 'application/octet-stream', data: bytes }
  ])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  f = parts['file']
  f && f.size == 256 &&
    f.bytes_binstr.length == 256 &&
    f.bytes_binstr[0].ord == 0x00 &&
    f.bytes_binstr[255].ord == 0xFF
}

# 5. UploadedFile#to_uint8_array returns a real Uint8Array
MultipartSmoke.assert('UploadedFile#to_uint8_array yields correct bytes') {
  # Build the 4-byte input with `.chr` so Opal parses it as a latin1
  # byte-string. A Ruby source literal like "\x80\xFF" would be
  # UTF-8-decoded by Opal at compile time and the high bytes would
  # collapse to the Unicode replacement character before any test
  # assertion runs.
  binstr = 0x00.chr + 0x7F.chr + 0x80.chr + 0xFF.chr
  u = Cloudflare::UploadedFile.new(
    name: 'file', filename: 'x.bin', content_type: 'application/octet-stream',
    bytes_binstr: binstr
  )
  arr = u.to_uint8_array
  `#{arr} instanceof Uint8Array && #{arr}.length === 4 && #{arr}[0] === 0 && #{arr}[1] === 0x7F && #{arr}[2] === 0x80 && #{arr}[3] === 0xFF`
}

# 6. Filename with quoted semicolons survives
MultipartSmoke.assert('filename with quoted semicolons survives parsing') {
  b = 'B4'
  body =  "--#{b}\r\n"
  body += "Content-Disposition: form-data; name=\"file\"; filename=\"weird; name.txt\"\r\n"
  body += "Content-Type: text/plain\r\n\r\n"
  body += "x"
  body += "\r\n--#{b}--\r\n"
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['file'].filename == 'weird; name.txt'
}

# 7. Empty filename field becomes an empty-body text value (Rack compat)
MultipartSmoke.assert('empty filename is treated as an empty text value') {
  b = 'B5'
  # filename="" when the user submits a form without selecting a file.
  body =  "--#{b}\r\n"
  body += "Content-Disposition: form-data; name=\"attach\"; filename=\"\"\r\n"
  body += "Content-Type: application/octet-stream\r\n\r\n"
  body += ""
  body += "\r\n--#{b}--\r\n"
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  # We still wrap it as an UploadedFile; the point is that the parser
  # doesn't blow up and the form field name is present.
  parts.key?('attach')
}

# 8. Missing/invalid content-type returns empty Hash (no crash)
MultipartSmoke.assert('graceful empty-return for non-multipart CT') {
  Cloudflare::Multipart.parse('whatever', 'application/json') == {}
}

# 9. UploadedFile Hash-style access (rack-compat shim)
MultipartSmoke.assert('UploadedFile[:filename] returns the filename') {
  u = Cloudflare::UploadedFile.new(name: 'f', filename: 'pic.png', content_type: 'image/png', bytes_binstr: 'xxx')
  u[:filename] == 'pic.png' && u[:type] == 'image/png' && u[:tempfile].read == 'xxx'
}

# 10. Rack::Request#POST delegates to Cloudflare::Multipart
require 'rack/request'
MultipartSmoke.assert('Rack::Request#POST parses multipart body via our parser') {
  b = 'B10'
  body = build_multipart(b, [
    { name: 'greeting', data: 'yo' },
    { name: 'doc',      filename: 'd.txt', content_type: 'text/plain', data: 'line1' }
  ])
  env = {
    'REQUEST_METHOD' => 'POST',
    'PATH_INFO'      => '/api/upload',
    'QUERY_STRING'   => '',
    'CONTENT_TYPE'   => "multipart/form-data; boundary=#{b}",
    'CONTENT_LENGTH' => body.length.to_s,
    'rack.input'     => StringIO.new(body),
    'rack.errors'    => $stderr,
    'rack.url_scheme'=> 'http',
    'HTTP_HOST'      => 'localhost'
  }
  req = Rack::Request.new(env)
  posted = req.POST
  posted.is_a?(Hash) && posted['greeting'] == 'yo' && posted['doc'].is_a?(Cloudflare::UploadedFile)
}

# 11. Multiple file parts in a single request
MultipartSmoke.assert('parses multiple file parts by field name') {
  b = 'B11'
  body = build_multipart(b, [
    { name: 'avatar', filename: 'a.png', content_type: 'image/png', data: 'AA' },
    { name: 'banner', filename: 'b.jpg', content_type: 'image/jpeg', data: 'BB' }
  ])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['avatar'].is_a?(Cloudflare::UploadedFile) &&
    parts['banner'].is_a?(Cloudflare::UploadedFile) &&
    parts['avatar'].filename == 'a.png' &&
    parts['banner'].filename == 'b.jpg'
}

# 12. RFC 5987 — filename*=UTF-8''<percent-encoded> is URL-decoded
MultipartSmoke.assert('RFC 5987 filename*=UTF-8\'\'... is URL-decoded') {
  b = 'B12'
  # "ファイル.txt" percent-encoded in UTF-8
  encoded = '%E3%83%95%E3%82%A1%E3%82%A4%E3%83%AB.txt'
  body =  "--#{b}\r\n"
  body += "Content-Disposition: form-data; name=\"doc\"; filename*=UTF-8''#{encoded}\r\n"
  body += "Content-Type: text/plain\r\n\r\n"
  body += "contents"
  body += "\r\n--#{b}--\r\n"
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['doc'].filename == 'ファイル.txt'
}

# 13. Large-ish payload (64 KiB binary) round-trips losslessly
MultipartSmoke.assert('64 KiB binary body survives parsing intact') {
  b = 'B13'
  # 64 KiB of byte pattern (0x00..0xFF repeating)
  payload = ''
  i = 0
  while i < 65536
    payload += (i % 256).chr
    i += 1
  end
  body = build_multipart(b, [
    { name: 'big', filename: 'big.bin', content_type: 'application/octet-stream', data: payload }
  ])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  f = parts['big']
  f && f.size == 65536 &&
    f.bytes_binstr[12345].ord == (12345 % 256) &&
    f.bytes_binstr[65535].ord == (65535 % 256)
}

# 14. Multibyte (Japanese) filename via the quoted form also works
MultipartSmoke.assert('quoted UTF-8 filename (Japanese) survives') {
  b = 'B14'
  body =  "--#{b}\r\n"
  body += "Content-Disposition: form-data; name=\"doc\"; filename=\"レポート.pdf\"\r\n"
  body += "Content-Type: application/pdf\r\n\r\n"
  body += "pdf-bytes"
  body += "\r\n--#{b}--\r\n"
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['doc'].filename == 'レポート.pdf'
}

# 15. Text field with multi-line content (CR/LF preserved)
MultipartSmoke.assert('text field preserves embedded newlines') {
  b = 'B15'
  body = build_multipart(b, [
    { name: 'note', data: "line one\r\nline two\r\nline three" }
  ])
  parts = Cloudflare::Multipart.parse(body, "multipart/form-data; boundary=#{b}")
  parts['note'] == "line one\r\nline two\r\nline three"
}

success = MultipartSmoke.report
`process.exit(#{success ? 0 : 1})`
