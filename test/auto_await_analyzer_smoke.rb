# frozen_string_literal: true
# backtick_javascript: true
#
# Phase 17.5 — Auto-Await analyzer smoke tests.
#
# Covers:
#   1. User-defined wrapper methods returning async-tainted objects.
#   2. env[...] accessor inference.
#   3. helper_factory propagation through def scope.
#
# Usage:
#   npm run test:auto-await
#   npm test

require 'json'

$LOAD_PATH.unshift(File.expand_path('../gems/homura-runtime/lib', __dir__))
require 'cloudflare_workers/async_registry'
require 'cloudflare_workers/auto_await/analyzer'

module SmokeTest
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
      $stderr.puts "  FAIL  #{label}"
    end
  rescue => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stderr.puts "  ERROR #{label} — #{e.class}: #{e.message}"
  end

  def self.summary
    total = @passed + @failed
    $stdout.puts "\n#{total} tests, #{@passed} passed, #{@failed} failed"
    exit(@failed.positive? ? 1 : 0)
  end
end

# ------------------------------------------------------------------
# Setup: register the same async sources the real build uses.
# ------------------------------------------------------------------

CloudflareWorkers::AsyncRegistry.reset!

CloudflareWorkers::AsyncRegistry.register_async_source do
  async_accessor :env, :'cloudflare.DB', 'Cloudflare::D1Database'
  async_accessor :env, :'cloudflare.KV', 'Cloudflare::KVNamespace'
  helper_factory :db,  'Cloudflare::D1Database'
  helper_factory :kv,  'Cloudflare::KVNamespace'
  async_method 'Cloudflare::D1Database', :execute
  async_method 'Cloudflare::KVNamespace', :get
  async_method 'Cloudflare::AI', :run
  async_helper :load_chat_history, 'Homura::ChatHistoryHelpers'
end

# ------------------------------------------------------------------
# Helper: run analyzer on a snippet and return the list of await
# source strings.
# ------------------------------------------------------------------

def analyze(source)
  registry = CloudflareWorkers::AsyncRegistry.instance
  analyzer = CloudflareWorkers::AutoAwait::Analyzer.new(registry)
  _buffer, nodes = analyzer.process(source, '(smoke)')
  nodes.map { |n| n.loc.expression.source }
end

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------

$stdout.puts "Auto-Await Analyzer Smoke Tests"
$stdout.puts "=" * 40

# 1. Direct env accessor inference
SmokeTest.assert("env['cloudflare.DB'].execute is awaited") do
  source = <<~RUBY
    get '/test' do
      env['cloudflare.DB'].execute('SELECT 1')
    end
  RUBY
  analyze(source).include?("env['cloudflare.DB'].execute('SELECT 1')")
end

# 2. helper_factory propagation
SmokeTest.assert("db.execute is awaited via helper_factory") do
  source = <<~RUBY
    get '/test' do
      db.execute('SELECT 1')
    end
  RUBY
  analyze(source).include?("db.execute('SELECT 1')")
end

# 3. User-defined wrapper returning env accessor
SmokeTest.assert("user-defined wrapper my_db returns D1Database") do
  source = <<~RUBY
    def my_db
      env['cloudflare.DB']
    end

    get '/test' do
      my_db.execute('SELECT 1')
    end
  RUBY
  analyze(source).include?("my_db.execute('SELECT 1')")
end

# 4. User-defined wrapper returning helper_factory result
SmokeTest.assert("user-defined wrapper my_kv returns KVNamespace") do
  source = <<~RUBY
    def my_kv
      kv
    end

    get '/test' do
      my_kv.get('key')
    end
  RUBY
  analyze(source).include?("my_kv.get('key')")
end

# 5. No false positives on non-async methods
SmokeTest.assert("String#length is NOT awaited") do
  source = <<~RUBY
    get '/test' do
      x = "hello"
      x.length
    end
  RUBY
  !analyze(source).include?("x.length")
end

# 6. Nested env accessor inference
SmokeTest.assert("env['cloudflare.KV'].get is awaited") do
  source = <<~RUBY
    get '/test' do
      env['cloudflare.KV'].get('key')
    end
  RUBY
  analyze(source).include?("env['cloudflare.KV'].get('key')")
end

# 7. Helper body using helper_factory result
SmokeTest.assert("helper method body using kv.get is awaited") do
  source = <<~RUBY
    helpers do
      def load_todos
        raw = kv.get('todos')
        raw ? JSON.parse(raw) : []
      end
    end
  RUBY
  analyze(source).include?("kv.get('todos')")
end

# 8. async_helper call sites stay sync-shaped in source
SmokeTest.assert("async_helper load_chat_history is awaited") do
  source = <<~RUBY
    post '/api/chat/messages' do
      history = load_chat_history(session_id)
      history.size
    end
  RUBY
  analyze(source).include?('load_chat_history(session_id)')
end

# 9. Async class methods like Cloudflare::AI.run are awaited
SmokeTest.assert("Cloudflare::AI.run is awaited") do
  source = <<~RUBY
    post '/ai' do
      result = Cloudflare::AI.run(model, { messages: [] }, binding: env['cloudflare.AI'])
      result.to_s
    end
  RUBY
  analyze(source).include?("Cloudflare::AI.run(model, { messages: [] }, binding: env['cloudflare.AI'])")
end

SmokeTest.summary
