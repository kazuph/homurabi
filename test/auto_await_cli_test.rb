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

repo_root = File.expand_path('..', __dir__)
cli = File.join(repo_root, 'gems', 'homura-runtime', 'exe', 'auto-await')

Dir.mktmpdir do |dir|
  input_dir = File.join(dir, 'app')
  output_dir = File.join(dir, 'build', 'auto_await')
  FileUtils.mkdir_p(input_dir)

  File.write(File.join(input_dir, 'manual_await.rb'), <<~RUBY)
    module Demo
      def self.fetch
        Cloudflare::KVNamespace.new.get('k').__await__
      end
    end
  RUBY

  File.write(File.join(input_dir, 'plain.rb'), <<~RUBY)
    module Demo
      def self.sync
        1 + 1
      end
    end
  RUBY

  File.write(File.join(input_dir, 'sequel_chain.rb'), <<~RUBY)
    require 'sequel'

    module Demo
      def self.rows(db)
        seq_db = Sequel.connect(adapter: :d1, d1: db)
        seq_db[:users].where(active: true).order(:name).limit(10).all
      end

      def self.row(db)
        seq_db = Sequel.connect(adapter: :d1, d1: db)
        seq_db[:users].where(id: 1).first
      end
    end
  RUBY

  ok = assert('auto-await emits file when only manual __await__ needs magic comment') do
    Dir.chdir(repo_root) do
      system('bundle', 'exec', 'ruby', cli, '--input', input_dir, '--output', output_dir) or raise 'auto-await failed'
    end
    manual = File.join(output_dir, 'manual_await.rb')
    raise 'missing rewritten file' unless File.exist?(manual)
    output = File.read(manual)
    raise output unless output.start_with?("# await: true\n")
    raise output unless output.include?(".__await__")
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('auto-await still skips unchanged sync-only files') do
    plain = File.join(output_dir, 'plain.rb')
    raise 'unexpected rewritten sync file' if File.exist?(plain)
  end
  passed += 1 if ok
  failed += 1 unless ok

  ok = assert('auto-await loads sequel-d1 async sources for Dataset chains') do
    Dir.chdir(repo_root) do
      system('bundle', 'exec', 'ruby', cli, '--input', input_dir, '--output', output_dir) or raise 'auto-await failed'
    end
    sequel = File.join(output_dir, 'sequel_chain.rb')
    raise 'missing rewritten sequel file' unless File.exist?(sequel)
    output = File.read(sequel)
    raise output unless output.start_with?("# await: true\n")
    raise output unless output.include?('seq_db[:users].where(active: true).order(:name).limit(10).all.__await__')
    raise output unless output.include?('seq_db[:users].where(id: 1).first.__await__')
  end
  passed += 1 if ok
  failed += 1 unless ok
end

puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
