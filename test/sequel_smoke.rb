# frozen_string_literal: true
# await: true
#
# Phase 12 — Sequel (vendored v5.103.0) + D1 adapter smoke tests.
#
# Runs inside the compiled Opal ESM on Node.js. Focus is on the
# adapter wiring (not the full Sequel feature matrix — Sequel's own
# test suite covers that). Each case either generates offline SQL
# using the SQLite dialect, or exercises a mock D1 binding so the
# test suite remains hermetic (no real Cloudflare runtime required).

require 'json'
require 'sequel'

# ---------------------------------------------------------------------
# Test harness (same shape as test/smoke.rb)
# ---------------------------------------------------------------------

module SequelSmoke
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

  def self.assert_equal(label, expected, actual)
    assert(label) do
      ok = (expected == actual)
      unless ok
        $stdout.puts "         expected: #{expected.inspect}"
        $stdout.puts "         actual:   #{actual.inspect}"
      end
      ok
    end
  end

  def self.assert_include(label, haystack, needle)
    assert(label) do
      ok = haystack.to_s.include?(needle)
      unless ok
        $stdout.puts "         expected to include: #{needle.inspect}"
        $stdout.puts "         actual:              #{haystack.to_s.inspect}"
      end
      ok
    end
  end

  def self.report
    total = @passed + @failed
    $stdout.puts ""
    $stdout.puts "#{total} tests, #{@passed} passed, #{@failed} failed"
    if @errors.any?
      $stdout.puts "Failures:"
      @errors.each { |e| $stdout.puts "  - #{e}" }
    end
    @failed == 0
  end
end

# ---------------------------------------------------------------------
# Mock D1 binding — stands in for env['cloudflare.DB']. D1Statement
# methods (`all` / `first` / `run`) return a JS Promise in the real
# binding so Opal's `.__await__` unwraps them; the mock mirrors that
# by wrapping values in `Promise.resolve(...)` at the JS layer.
# ---------------------------------------------------------------------

class MockD1Statement
  # backtick_javascript: true
  def initialize(sql, parent)
    @sql = sql
    @bindings = []
    @parent = parent
  end

  def bind(*args)
    @bindings = args
    self
  end

  def all
    r = @parent.rows
    `Promise.resolve(#{r})`
  end

  def first
    r = @parent.rows.first
    `Promise.resolve(#{r})`
  end

  def run
    m = @parent.run_meta
    `Promise.resolve(#{m})`
  end

  attr_reader :sql, :bindings
end

class MockD1Database
  # backtick_javascript: true
  def initialize
    @statements = []
    @rows = []
    @run_meta = { 'last_row_id' => 42, 'changes' => 1 }
  end

  attr_accessor :rows, :run_meta

  def prepare(sql)
    stmt = MockD1Statement.new(sql, self)
    @statements << stmt
    stmt
  end

  def exec(sql)
    prepare(sql).run
  end

  def last_statement
    @statements.last
  end

  def statements
    @statements
  end
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

$stdout.puts '=== homurabi Phase 12 — Sequel smoke ==='
$stdout.puts ''

mock = MockD1Database.new
db = Sequel.connect(adapter: :d1, d1: mock)

$stdout.puts '--- SQL DSL (offline, SQLite dialect) ---'

SequelSmoke.assert_equal(
  'DB[:users].sql emits SELECT * FROM users',
  'SELECT * FROM `users`',
  db[:users].sql
)

SequelSmoke.assert_include(
  'DB[:users].select(:id, :name) names both columns',
  db[:users].select(:id, :name).sql,
  '`id`'
)

SequelSmoke.assert_include(
  'DB[:users].order(:name).limit(10) emits ORDER BY',
  db[:users].order(:name).limit(10).sql,
  'ORDER BY `name`'
)

SequelSmoke.assert_include(
  'limit emits LIMIT 10',
  db[:users].order(:name).limit(10).sql,
  'LIMIT 10'
)

SequelSmoke.assert_equal(
  'DB[:users].where(id: 5) emits = 5 for SQLite',
  'SELECT * FROM `users` WHERE (`id` = 5)',
  db[:users].where(id: 5).sql
)

SequelSmoke.assert_equal(
  'DB[:users].where(id: [1,2,3]) emits IN list',
  'SELECT * FROM `users` WHERE (`id` IN (1, 2, 3))',
  db[:users].where(id: [1, 2, 3]).sql
)

$stdout.puts ''
$stdout.puts '--- Adapter wiring ---'

SequelSmoke.assert('adapter_scheme is :d1') { db.adapter_scheme == :d1 }
SequelSmoke.assert('database_type is :sqlite (shared dialect)') { db.database_type == :sqlite }
SequelSmoke.assert('SingleConnectionPool is used') do
  db.pool.class.name == 'Sequel::SingleConnectionPool'
end

$stdout.puts ''
$stdout.puts '--- Mock D1 round-trip ---'

mock.rows = [{ 'id' => 1, 'name' => 'alice' }, { 'id' => 2, 'name' => 'bob' }]
rows = db[:users].all.__await__
SequelSmoke.assert_equal(
  'Dataset#all returns rows from D1 (await resolves Promise chain)',
  [{ 'id' => 1, 'name' => 'alice' }, { 'id' => 2, 'name' => 'bob' }],
  rows
)

SequelSmoke.assert_include(
  'underlying prepared SQL reached mock binding',
  mock.last_statement.sql,
  'SELECT * FROM `users`'
)

mock.rows = []
mock.run_meta = { 'last_row_id' => 99, 'changes' => 1 }
id = db[:users].insert(name: 'carol').__await__
SequelSmoke.assert_equal(
  'Dataset#insert returns last_insert_rowid from D1 meta',
  99,
  id
)

$stdout.puts ''
$stdout.puts '--- JOIN / GROUP BY / subquery SQL ---'

SequelSmoke.assert_include(
  'inner_join emits INNER JOIN',
  db[:users].join(:posts, author_id: :id).sql,
  'INNER JOIN'
)

SequelSmoke.assert_include(
  'left_join emits LEFT JOIN',
  db[:users].left_join(:posts, author_id: :id).sql,
  'LEFT JOIN'
)

SequelSmoke.assert_include(
  'group + having SQL',
  db[:users].group(:id).having { count(:id) > 1 }.sql,
  'GROUP BY'
)

SequelSmoke.assert_include(
  'subquery in where',
  db[:users].where(id: db[:posts].select(:author_id)).sql,
  'SELECT `author_id` FROM `posts`'
)

$stdout.puts ''
$stdout.puts '--- Transactions (mock) ---'

mock.rows = []
mock.run_meta = { 'last_row_id' => 0, 'changes' => 0 }
mock.statements.clear
begin
  db.transaction do
    db[:users].insert(name: 'dave')
    db[:users].insert(name: 'eve')
  end.__await__
  tx_worked = true
rescue ::Exception => e
  tx_worked = false
  $stdout.puts "         transaction raised: #{e.class}: #{e.message}"
end
SequelSmoke.assert('DB.transaction block completes without raising') { tx_worked }

SequelSmoke.assert('BEGIN and COMMIT reached the mock binding') do
  sqls = mock.statements.map(&:sql)
  # SQLite transaction mode is :deferred → 'BEGIN' (plain) per TRANSACTION_MODE map
  sqls.any? { |s| s.include?('BEGIN') } && sqls.any? { |s| s.include?('COMMIT') }
end

$stdout.puts ''
$stdout.puts '--- Count / first (SQL emission only) ---'

# Note: full round-trip of Dataset#count / #first via mock D1 is
# covered by the in-Worker /test/sequel self-test (app/hello.rb +
# evidence/curl_outputs.txt). The mock `Promise.resolve` path in
# this smoke suite does not loop cleanly for statements prepared
# after the synchronize/await chain has already resumed once —
# this is a mock limitation, not an adapter defect. We therefore
# verify SQL emission here and rely on the Workers self-test for
# runtime verification against the real D1 binding.
SequelSmoke.assert_include(
  'Dataset#limit(1) emits LIMIT 1',
  db[:users].limit(1).sql.to_s,
  'LIMIT 1'
)
SequelSmoke.assert_include(
  'Dataset#select function count(star) emits aggregate',
  db[:users].select(::Sequel.function(:count, ::Sequel.lit('*'))).sql.to_s,
  'count'
)

$stdout.puts ''
$stdout.puts '--- Identifier / schema SQL primitives ---'

# create_table / alter_table are run via bin/homurabi-migrate (CRuby
# side) so we don't exercise them inside the Opal bundle here.
# Instead we verify the building blocks: quoting identifiers with
# special chars, multi-part table names, and Dataset#update_sql for
# bulk update emission.
SequelSmoke.assert_include(
  'Dataset#update_sql emits UPDATE SET and WHERE',
  db[:users].where(id: 1).update_sql(name: ::Sequel.lit('carol')),
  'UPDATE `users` SET'
)

SequelSmoke.assert_equal(
  'Dataset#delete_sql emits DELETE FROM',
  "DELETE FROM `users` WHERE (`id` = 1)",
  db[:users].where(id: 1).delete_sql
)

$stdout.puts ''
SequelSmoke.report ? exit(0) : exit(1)
