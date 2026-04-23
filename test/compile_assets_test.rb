# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

passed = 0
failed = 0

def assert(label)
  yield
  puts "PASS #{label}"
  true
rescue => e
  warn "FAIL #{label}: #{e.class}: #{e.message}"
  false
end

Dir.mktmpdir do |dir|
  public_dir = File.join(dir, 'public')
  out_path = File.join(dir, 'embedded_assets.rb')
  FileUtils.mkdir_p(public_dir)

  File.binwrite(File.join(public_dir, 'sample.png'), "\x89PNG\r\n\x1A\n".b + "BIN".b)
  File.write(File.join(public_dir, 'sample.svg'), '<svg xmlns="http://www.w3.org/2000/svg"></svg>')

  script = File.expand_path('../gems/homura-runtime/exe/compile-assets', __dir__)
  Dir.chdir(dir) do
    system('ruby', script, '--input', 'public', '--output', 'embedded_assets.rb', '--namespace', 'CompileAssetsTest') or abort('compile-assets failed')
  end

  module ::Cloudflare
    class RawResponse
      attr_reader :js_response

      def initialize(js_response)
        @js_response = js_response
      end
    end

    class EmbeddedBinaryBody
      attr_reader :body_base64, :content_type, :cache_control

      def initialize(body_base64, content_type = 'application/octet-stream', cache_control = nil)
        @body_base64 = body_base64
        @content_type = content_type
        @cache_control = cache_control
      end

      def raw_response(_status, _headers = {})
        RawResponse.new(:fake_js_response)
      end
    end
  end

  load out_path

  ok = assert('binary asset is returned as RawResponse via EmbeddedBinaryBody') do
    app = ->(_env) { [404, {}, ['miss']] }
    status, headers, body = CompileAssetsTest::Middleware.new(app).call('PATH_INFO' => '/sample.png')
    raise "status=#{status}" unless status == 200
    raise "content-type=#{headers['content-type']}" unless headers['content-type'] == 'image/png'
    raise 'expected single-element rack body' unless body.is_a?(Array) && body.length == 1
    raise 'binary body not converted to RawResponse' unless body.first.is_a?(Cloudflare::RawResponse)
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('text asset stays a plain String body') do
    app = ->(_env) { [404, {}, ['miss']] }
    status, headers, body = CompileAssetsTest::Middleware.new(app).call('PATH_INFO' => '/sample.svg')
    raise "status=#{status}" unless status == 200
    raise "content-type=#{headers['content-type']}" unless headers['content-type'] == 'image/svg+xml'
    raise 'expected plain string body' unless body.first.is_a?(String)
    raise 'content-length missing' unless headers['content-length'] == body.first.bytesize.to_s
  end
  passed += 1 if ok
  failed += 1 unless ok
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
