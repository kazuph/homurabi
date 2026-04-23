# frozen_string_literal: true

require 'fileutils'
require 'open3'
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
  views_dir = File.join(dir, 'views')
  load_path_dir = File.join(dir, 'load_path')
  out_path = File.join(dir, 'compiled_templates.rb')
  FileUtils.mkdir_p(views_dir)
  FileUtils.mkdir_p(File.join(load_path_dir, 'sinatra'))

  File.write(File.join(views_dir, 'index.erb'), '<p>Hello <%= @name %></p>')
  File.write(File.join(views_dir, 'layout.erb'), '<main><%= yield %></main>')
  File.write(File.join(views_dir, 'layout_docs.erb'), '<article><%= yield %></article>')
  File.write(File.join(load_path_dir, 'sinatra', 'base.rb'), "module Sinatra\n  module Templates\n  end\nend\n")

  script = File.expand_path('../gems/homura-runtime/exe/compile-erb', __dir__)
  Dir.chdir(dir) do
    system('ruby', script, '--input', 'views', '--output', 'compiled_templates.rb', '--namespace', 'CompileErbTest') or abort('compile-erb failed')
  end

  $LOAD_PATH.unshift(load_path_dir)
  load out_path

  app_class = Class.new do
    include Sinatra::Templates
  end

  ok = assert('erb supports explicit Sinatra-style layout option') do
    app = app_class.new
    app.instance_variable_set(:@name, 'homura')
    html = app.erb(:index, layout: :layout)
    raise html unless html == '<main><p>Hello homura</p></main>'
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('erb keeps default no-layout behavior for compatibility') do
    app = app_class.new
    app.instance_variable_set(:@name, 'homura')
    html = app.erb(:index)
    raise html unless html == '<p>Hello homura</p>'
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('legacy @content layout fallback still works') do
    app = app_class.new
    app.instance_variable_set(:@content, '<p>legacy</p>')
    html = app.erb(:layout)
    raise html unless html == '<main><p>legacy</p></main>'
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('legacy @docs_inner layout fallback still works') do
    app = app_class.new
    app.instance_variable_set(:@docs_inner, '<section>docs</section>')
    html = app.erb(:layout_docs)
    raise html unless html == '<article><section>docs</section></article>'
  end
  passed += 1 if ok
  failed += 1 unless ok

  {
    'compile-erb rejects <% yield %>' => {
      script: File.expand_path('../gems/homura-runtime/exe/compile-erb', __dir__),
      body: '<% yield %>'
    },
    'compile-erb rejects <%= yield(arg) %>' => {
      script: File.expand_path('../gems/homura-runtime/exe/compile-erb', __dir__),
      body: '<%= yield(:body) %>'
    },
    'cloudflare-workers-erb-compile rejects <% yield %>' => {
      script: File.expand_path('../gems/sinatra-homura/bin/cloudflare-workers-erb-compile', __dir__),
      body: '<% yield %>'
    },
    'cloudflare-workers-erb-compile rejects <%= yield(arg) %>' => {
      script: File.expand_path('../gems/sinatra-homura/bin/cloudflare-workers-erb-compile', __dir__),
      body: '<%= yield(:body) %>'
    }
  }.each do |label, spec|
    ok = assert(label) do
      invalid_path = File.join(views_dir, 'invalid.erb')
      File.write(invalid_path, spec[:body])
      output, status = Dir.chdir(dir) do
        Open3.capture2e('ruby', spec[:script], invalid_path)
      end
      raise 'unexpected success' if status.success?
      raise output unless output.include?('Unsupported ERB yield form')
      raise output unless output.include?('<%= yield %>') && output.include?('<%== yield %>')
    ensure
      FileUtils.rm_f(invalid_path)
    end
    passed += 1 if ok
    failed += 1 unless ok
  end
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
