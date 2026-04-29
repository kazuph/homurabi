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

    config_ru = File.read(File.join(app_dir, 'config.ru'))
    raise 'config.ru should require app/app relatively' unless config_ru.include?("require_relative 'app/app'")
    # As of sinatra-homura 0.2.23, `run App` is no longer required —
    # `Sinatra::Homura.ensure_rack_app!` discovers and
    # registers `App` on the first fetch event. Scaffolder must NOT emit it.
    raise 'config.ru should not emit `run App` (auto-registered now)' if config_ru.include?('run App')

    app_rb = File.read(File.join(app_dir, 'app', 'app.rb'))
    raise 'app/app.rb should not call run App directly' if app_rb.include?('run App')
    raise 'app/app.rb should require sinatra/base' unless app_rb.include?("require 'sinatra/base'")
    raise 'app/app.rb should not require legacy sinatra/homura' if app_rb.include?("require 'sinatra/homura'")

    gemfile = File.read(File.join(app_dir, 'Gemfile'))
    raise 'Gemfile should include rake for generated tasks' unless gemfile.include?("gem 'rake'")

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

    gemfile = File.read(File.join(app_dir, 'Gemfile'))
    raise 'Gemfile should include sequel-d1' unless gemfile.include?("gem 'sequel-d1'")

    rakefile = File.read(File.join(app_dir, 'Rakefile'))
    raise 'Rake build task should pass --with-db' unless rakefile.include?("'homura', 'build', '--standalone', '--with-db'")
    raise 'Rake db:migrate:compile task missing' unless rakefile.include?("task :compile do")
    raise 'Rake db:migrate:local task missing' unless rakefile.include?("task local: :compile do")
    raise 'Rake db:migrate:remote task missing' unless rakefile.include?("task remote: :compile do")

    wrangler = File.read(File.join(app_dir, 'wrangler.toml'))
    raise 'wrangler.toml should include nodejs_compat' unless wrangler.include?('compatibility_flags = ["nodejs_compat"]')
    raise 'wrangler.toml should include D1 binding' unless wrangler.include?('[[d1_databases]]')
    raise 'wrangler.toml should include migrations_dir' unless wrangler.include?('migrations_dir = "db/migrate"')

    migration = File.read(File.join(app_dir, 'db', 'migrate', '001_create_users.rb'))
    raise 'sample migration should create users table' unless migration.include?('create_table?(:users)')

    package = JSON.parse(File.read(File.join(app_dir, 'package.json')))
    raise 'package migrate compile script missing' unless package.dig('scripts', 'db:migrate:compile') == 'bundle exec rake db:migrate:compile'
    raise 'package migrate local script missing' unless package.dig('scripts', 'db:migrate:local') == 'bundle exec rake db:migrate:local'
    raise 'package migrate remote script missing' unless package.dig('scripts', 'db:migrate:remote') == 'bundle exec rake db:migrate:remote'
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'custom-entrypoint-app')
  FileUtils.mkdir_p(File.join(app_dir, 'app'))
  FileUtils.mkdir_p(File.join(app_dir, 'views'))
  FileUtils.mkdir_p(File.join(app_dir, 'public'))

  File.write(File.join(app_dir, 'app', 'app.rb'), <<~RUBY)
    # frozen_string_literal: true
    require 'sinatra/base'

    class App < Sinatra::Base
      get('/') { 'custom-entrypoint-ok' }
    end
  RUBY

  File.write(File.join(app_dir, 'config.ru'), <<~RUBY)
    # frozen_string_literal: true
    require_relative 'app/app'

  RUBY

  File.write(File.join(app_dir, 'views', 'index.erb'), "ok\n")
  File.write(File.join(app_dir, 'public', 'robots.txt'), "User-agent: *\n")

  ok = assert('standalone build derives relative entrypoint imports for custom output paths') do
    output, status = Open3.capture2e(
      bundle_env, 'bundle', 'exec', 'ruby', build_cli,
      '--root', app_dir,
      '--standalone',
      '--output', 'build/bundle.mjs',
      '--entrypoint-out', 'build/worker.entrypoint.mjs'
    )
    raise output unless status.success?

    entrypoint = File.read(File.join(app_dir, 'build', 'worker.entrypoint.mjs'))
    raise entrypoint unless entrypoint.include?('import "./cf-runtime/setup-node-crypto.mjs";')
    raise entrypoint unless entrypoint.include?('import "./bundle.mjs";')
    raise entrypoint unless entrypoint.include?('from "./cf-runtime/worker_module.mjs";')

    node_script = <<~JS
      const mod = await import(process.argv[2]);
      const app = mod.default;
      const ctx = { waitUntil() {} };
      const resp = await app.fetch(new Request('https://example.test/'), {}, ctx);
      console.log(`${resp.status}:${await resp.text()}`);
    JS
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'build', 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?
    raise output unless output.lines.map(&:strip).include?('200:custom-entrypoint-ok')
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
    require 'sinatra/base'

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
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'build', 'worker.entrypoint.mjs'), stdin_data: node_script)
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
    require 'sinatra/base'

    class App < Sinatra::Base
      get('/') { 'ok-from-app-rb' }
    end

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
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'build', 'worker.entrypoint.mjs'), stdin_data: node_script)
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
    require 'sinatra/base'

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
    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'build', 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?
    lines = output.lines.map(&:strip)
    raise output unless lines.include?('200:item:42')
    raise output unless lines.include?('200:async-item:42')
  end
  passed += 1 if ok
  failed += 1 unless ok
end

Dir.mktmpdir do |dir|
  app_dir = File.join(dir, 'standalone-db-app')
  FileUtils.mkdir_p(File.join(app_dir, 'app'))
  FileUtils.mkdir_p(File.join(app_dir, 'views'))
  FileUtils.mkdir_p(File.join(app_dir, 'public'))

  File.write(File.join(app_dir, 'app', 'app.rb'), <<~RUBY)
    # frozen_string_literal: true
    require 'sinatra/base'
    require 'sequel'
    require 'json'

    class App < Sinatra::Base
      helpers do
        def db
          @db ||= Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
        end
      end

      get '/' do
        @todos = db[:todos].order(:id).all
        erb :index
      end

      get '/api/todos' do
        content_type 'application/json'
        { todos: db[:todos].order(:id).all }.to_json
      end

      post '/toggle/:id' do
        id = params['id'].to_i
        todo = db[:todos].first(id: id)
        db[:todos].where(id: id).update(completed: !todo[:completed]) if todo
        redirect '/'
      end
    end

  RUBY

  File.write(File.join(app_dir, 'config.ru'), <<~RUBY)
    # frozen_string_literal: true
    require_relative 'app/app'

  RUBY

  File.write(File.join(app_dir, 'views', 'index.erb'), <<~ERB)
    <li class="<%= 'completed' if @todos.first[:completed] %>"><%= @todos.first[:text] %></li>
  ERB
  File.write(File.join(app_dir, 'views', 'layout.erb'), "<main><%= yield %></main>\n")
  File.write(File.join(app_dir, 'public', 'robots.txt'), "User-agent: *\n")

  ok = assert('standalone build auto-awaits sequel routes, coerces booleans, and applies default layout') do
    output, status = Open3.capture2e(bundle_env, 'bundle', 'exec', 'ruby', build_cli, '--root', app_dir, '--standalone', '--with-db')
    raise output unless status.success?

    node_script = <<~JS
      const mod = await import(process.argv[2]);
      const app = mod.default;
      const ctx = { waitUntil() {} };
      const env = {
        DB: {
          prepare(sql) {
            return {
              _sql: sql,
              bind(...args) { this._bindings = args; return this; },
              all() {
                if (this._sql.includes('PRAGMA table_xinfo')) {
                  return Promise.resolve({ results: [
                    { name: 'id', type: 'integer', notnull: 1, dflt_value: null, pk: 1 },
                    { name: 'text', type: 'text', notnull: 1, dflt_value: null, pk: 0 },
                    { name: 'completed', type: 'boolean', notnull: 1, dflt_value: '0', pk: 0 }
                  ] });
                }
                return Promise.resolve({ results: [{ id: 1, text: 'demo', completed: 0 }] });
              },
              run() {
                return Promise.resolve({ success: true, meta: { changes: 1, last_row_id: 1 } });
              }
            };
          }
        }
      };

      const indexResp = await app.fetch(new Request('http://127.0.0.1:8787/'), env, ctx);
      console.log(`GET:${indexResp.status}:${await indexResp.text()}`);

      const apiResp = await app.fetch(new Request('http://127.0.0.1:8787/api/todos'), env, ctx);
      console.log(`API:${apiResp.status}:${await apiResp.text()}`);

      const postResp = await app.fetch(new Request('http://127.0.0.1:8787/toggle/1', { method: 'POST' }), env, ctx);
      console.log(`POST:${postResp.status}:${postResp.headers.get('location')}`);
    JS

    output, status = Open3.capture2e('node', '--input-type=module', '-', File.join(app_dir, 'build', 'worker.entrypoint.mjs'), stdin_data: node_script)
    raise output unless status.success?

    lines = output.lines.map(&:strip)
    get_line = lines.find { |line| line.start_with?('GET:') }
    api_line = lines.find { |line| line.start_with?('API:') }
    post_line = lines.find { |line| line.start_with?('POST:') }

    raise output unless get_line&.include?('<main>')
    raise output if get_line&.include?('class="completed"')
    raise output unless api_line == 'API:200:{"todos":[{"id":1,"text":"demo","completed":false}]}'
    raise output unless post_line == 'POST:303:http://127.0.0.1:8787/'
  end
  passed += 1 if ok
  failed += 1 unless ok
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
