# frozen_string_literal: true

require 'fileutils'
require 'json'
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

repo_root = File.expand_path('..', __dir__)
cli = File.join(repo_root, 'gems', 'sinatra-homura', 'bin', 'homura')
build_cli = File.join(repo_root, 'gems', 'homura-runtime', 'exe', 'homura-build')
bundle_env = { 'BUNDLE_GEMFILE' => File.join(repo_root, 'Gemfile') }

ok = assert('homura CLI shows new subcommand usage') do
  output = `bundle exec ruby #{cli} 2>&1`
  raise "unexpected success" if $?.success?
  raise output unless output.include?('usage: homura COMMAND')
  raise output unless output.include?('build [options]')
  raise output unless output.include?('erb:compile')
  raise output unless output.include?('db:migrate:compile')
  raise output unless output.include?('db:migrate:apply')
  raise output unless output.include?('new APP_NAME [--with-db]')
end
passed += 1 if ok
failed += 1 unless ok

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'demo-app')
  ok = assert('homura new scaffolds a project') do
    Dir.chdir(repo_root) do
      system('bundle', 'exec', 'ruby', cli, 'new', app_dir) or raise 'homura new failed'
    end
    raise 'Gemfile missing' unless File.exist?(File.join(app_dir, 'Gemfile'))
    raise 'cf-runtime/setup-node-crypto.mjs missing' unless File.exist?(File.join(app_dir, 'cf-runtime', 'setup-node-crypto.mjs'))

    config_ru = File.read(File.join(app_dir, 'config.ru'))
    raise 'config.ru should run App' unless config_ru.include?('run App')

    app_rb = File.read(File.join(app_dir, 'app', 'app.rb'))
    raise 'app/app.rb should not call run App directly' if app_rb.include?('run App')

    rakefile = File.read(File.join(app_dir, 'Rakefile'))
    raise 'Rake build task missing' unless rakefile.include?("task :build do")
    raise 'Rake dev task missing' unless rakefile.include?("task dev: :build do")
    raise 'Rake deploy task missing' unless rakefile.include?("task deploy: :build do")

    package = JSON.parse(File.read(File.join(app_dir, 'package.json')))
    raise 'package build script should delegate to rake' unless package.dig('scripts', 'build') == 'bundle exec rake build'
    raise 'package dev script should delegate to rake' unless package.dig('scripts', 'dev') == 'bundle exec rake dev'
    raise 'package deploy script should delegate to rake' unless package.dig('scripts', 'deploy') == 'bundle exec rake deploy'
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'demo-db-app')
  ok = assert('homura new --with-db scaffolds build task with db flag') do
    Dir.chdir(repo_root) do
      system('bundle', 'exec', 'ruby', cli, 'new', app_dir, '--with-db') or raise 'homura new --with-db failed'
    end

    rakefile = File.read(File.join(app_dir, 'Rakefile'))
    raise 'Rake build task should pass --with-db' unless rakefile.include?("'homura', 'build', '--standalone', '--with-db'")
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'config-ru-app')
  FileUtils.mkdir_p(File.join(app_dir, 'app'))
  FileUtils.mkdir_p(File.join(app_dir, 'views'))
  FileUtils.mkdir_p(File.join(app_dir, 'public'))

  File.write(File.join(app_dir, 'app', 'app.rb'), <<~RUBY)
    # frozen_string_literal: true
    require 'sinatra/cloudflare_workers'

    class App < Sinatra::Base
      get('/') { 'ok-from-config-ru' }

      post '/create' do
        redirect '/'
      end
    end
  RUBY

  File.write(File.join(app_dir, 'config.ru'), <<~RUBY)
    # frozen_string_literal: true
    require_relative 'app/app'

    run App
  RUBY

  File.write(File.join(app_dir, 'views', 'index.erb'), "ok\n")
  File.write(File.join(app_dir, 'public', 'robots.txt'), "User-agent: *\n")

  ok = assert('standalone build uses config.ru without app/hello.rb and preserves redirect port') do
    output, status = Open3.capture2e(bundle_env, 'bundle', 'exec', 'ruby', build_cli, '--root', app_dir, '--standalone')
    raise output unless status.success?

    node_script = <<~JS
      const mod = await import(process.argv[2]);
      const app = mod.default;
      const ctx = { waitUntil() {} };

      const getResp = await app.fetch(new Request('http://127.0.0.1:8787/'), {}, ctx);
      console.log(`GET:${getResp.status}:${await getResp.text()}`);

      const postResp = await app.fetch(new Request('http://127.0.0.1:8787/create', { method: 'POST' }), {}, ctx);
      console.log(`POST:${postResp.status}:${postResp.headers.get('location')}`);
    JS
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?
    lines = output.lines.map(&:strip)
    raise output unless lines.include?('GET:200:ok-from-config-ru')
    raise output unless lines.include?('POST:303:http://127.0.0.1:8787/')
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'app-rb-entry')
  FileUtils.mkdir_p(File.join(app_dir, 'app'))
  FileUtils.mkdir_p(File.join(app_dir, 'views'))
  FileUtils.mkdir_p(File.join(app_dir, 'public'))

  File.write(File.join(app_dir, 'app', 'app.rb'), <<~RUBY)
    # frozen_string_literal: true
    require 'sinatra/cloudflare_workers'

    class App < Sinatra::Base
      get('/') { 'ok-from-app-rb' }
    end

    run App
  RUBY

  File.write(File.join(app_dir, 'views', 'index.erb'), "ok\n")
  File.write(File.join(app_dir, 'public', 'robots.txt'), "User-agent: *\n")

  ok = assert('standalone build falls back to app/app.rb without app/hello.rb') do
    output, status = Open3.capture2e(bundle_env, 'bundle', 'exec', 'ruby', build_cli, '--root', app_dir, '--standalone')
    raise output unless status.success?

    node_script = <<~JS
      const mod = await import(process.argv[2]);
      const app = mod.default;
      const ctx = { waitUntil() {} };
      const resp = await app.fetch(new Request('https://example.test/'), {}, ctx);
      console.log(`${resp.status}:${await resp.text()}`);
    JS
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?
    raise output unless output.lines.map(&:strip).include?('200:ok-from-app-rb')
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'standalone-app')
  FileUtils.mkdir_p(File.join(app_dir, 'app'))
  FileUtils.mkdir_p(File.join(app_dir, 'views'))
  FileUtils.mkdir_p(File.join(app_dir, 'public'))

  File.write(File.join(app_dir, 'app', 'app.rb'), <<~RUBY)
    # frozen_string_literal: true
    require 'sinatra/cloudflare_workers'

    class App < Sinatra::Base
      helpers do
        def await_tick
          `Promise.resolve(nil)`.__await__
        end
      end

      get('/items/:id') { "item:\#{params['id']}" }

      get '/async/items/:id' do
        await_tick
        "async-item:\#{params['id']}"
      end
    end

    run App
  RUBY

  File.write(File.join(app_dir, 'app', 'hello.rb'), <<~RUBY)
    # await: call
    # frozen_string_literal: true
    require 'app'
  RUBY

  File.write(File.join(app_dir, 'views', 'index.erb'), "ok\n")
  File.write(File.join(app_dir, 'public', 'robots.txt'), "User-agent: *\n")

  ok = assert('standalone build preserves route params across await') do
    output, status = Open3.capture2e(bundle_env, 'bundle', 'exec', 'ruby', build_cli, '--root', app_dir, '--standalone')
    raise output unless status.success?

    node_script = <<~JS
      const mod = await import(process.argv[2]);
      const app = mod.default;
      const ctx = { waitUntil() {} };
      for (const path of ['/items/42', '/async/items/42']) {
        const resp = await app.fetch(new Request(`https://example.test${path}`), {}, ctx);
        console.log(`${resp.status}:${await resp.text()}`);
      }
    JS
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?
    lines = output.lines.map(&:strip)
    raise output unless lines.include?('200:item:42')
    raise output unless lines.include?('200:async-item:42')
  end
  passed += 1 if ok
  failed += 1 unless ok
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
