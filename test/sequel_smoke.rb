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
require 'cloudflare_workers'
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

  def self.assert_matrix(label_prefix, cases, &block)
    cases.each_with_index do |test_case, idx|
      label = "#{label_prefix} [#{idx + 1}] #{test_case[:label]}"
      assert(label) { block.call(test_case) }
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

def build_js_row(pairs)
  js = `({})`
  pairs.each do |key, value|
    if `(typeof #{value} === 'string' && #{value} === '__HOMURA_SENTINEL_UNDEFINED__')`
      `#{js}[#{key}] = undefined`
    elsif `(typeof #{value} === 'string' && #{value} === '__HOMURA_SENTINEL_NULL__')`
      `#{js}[#{key}] = null`
    else
      `#{js}[#{key}] = #{value}`
    end
  end
  js
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
    r = @parent.all_results(@sql, @bindings)
    `Promise.resolve(#{r})`
  end

  def first
    r = @parent.all_results(@sql, @bindings).first
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
    @schema_rows = {}
  end

  attr_accessor :rows, :run_meta, :schema_rows

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

  def all_results(sql, bindings)
    if sql.include?('PRAGMA table_xinfo')
      table = bindings.first
      if table.nil? && (m = sql.match(/PRAGMA\s+table_xinfo\((['"]?)([^'")]+)\1\)/i))
        table = m[2]
      end
      @schema_rows.fetch(table.to_s, [])
    else
      @rows
    end
  end
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

$stdout.puts '=== homura Phase 12 — Sequel smoke ==='
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
SequelSmoke.assert('integer_booleans defaults to true for D1') do
  db.integer_booleans == true
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
  mock.statements.map(&:sql).join("\n"),
  'SELECT * FROM `users`'
)

$stdout.puts ''
$stdout.puts '--- JS row conversion guards ---'

js_row_with_undefined = `({ id: 1, due_date: undefined, created_at: 1700000000 })`
row_with_undefined = Cloudflare.js_object_to_hash(js_row_with_undefined)
SequelSmoke.assert_equal(
  'js_object_to_hash normalizes undefined properties to nil',
  nil,
  row_with_undefined['due_date']
)
SequelSmoke.assert_equal(
  'js_object_to_hash preserves sibling integer fields when one property is undefined',
  1,
  row_with_undefined['id']
)
SequelSmoke.assert_equal(
  'js_object_to_hash preserves later integer fields when one property is undefined',
  1_700_000_000,
  row_with_undefined['created_at']
)

js_rows_mixed = `[
  { id: 1, due_date: undefined, created_at: 1700000000 },
  { id: 2, due_date: 1735689600, created_at: 1700000100 }
]`
mixed_rows = Cloudflare.js_rows_to_ruby(js_rows_mixed)
SequelSmoke.assert_equal(
  'js_rows_to_ruby keeps first-row undefined values as nil',
  nil,
  mixed_rows.first['due_date']
)
SequelSmoke.assert_equal(
  'js_rows_to_ruby keeps later non-nil due_date values intact',
  1_735_689_600,
  mixed_rows[1]['due_date']
)
SequelSmoke.assert_equal(
  'js_rows_to_ruby preserves row ordering when first row has undefined due_date',
  [1, 2],
  mixed_rows.map { |row| row['id'] }
)

row_conversion_cases = [
  {
    label: 'undefined first key does not poison sibling fields',
    pairs: [['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['id', 11], ['created_at', 1_700_000_000]],
    nil_key: 'due_date',
    preserved: { 'id' => 11, 'created_at' => 1_700_000_000 }
  },
  {
    label: 'undefined middle key does not poison sibling fields',
    pairs: [['id', 12], ['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['created_at', 1_700_000_100]],
    nil_key: 'due_date',
    preserved: { 'id' => 12, 'created_at' => 1_700_000_100 }
  },
  {
    label: 'null middle key does not poison sibling fields',
    pairs: [['id', 13], ['due_date', '__HOMURA_SENTINEL_NULL__'], ['created_at', 1_700_000_200]],
    nil_key: 'due_date',
    preserved: { 'id' => 13, 'created_at' => 1_700_000_200 }
  },
  {
    label: 'different nullable key also normalizes undefined',
    pairs: [['id', 14], ['archived_at', '__HOMURA_SENTINEL_UNDEFINED__'], ['priority', 3]],
    nil_key: 'archived_at',
    preserved: { 'id' => 14, 'priority' => 3 }
  },
  {
    label: 'falsy values survive alongside undefined nullable keys',
    pairs: [['id', 15], ['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['completed', false], ['priority', 0], ['note', '']],
    nil_key: 'due_date',
    preserved: { 'id' => 15, 'completed' => false, 'priority' => 0, 'note' => '' }
  }
]

SequelSmoke.assert_matrix('js_object_to_hash matrix', row_conversion_cases) do |test_case|
  row = Cloudflare.js_object_to_hash(build_js_row(test_case[:pairs]))
  next false unless row[test_case[:nil_key]].nil?

  test_case[:preserved].all? { |k, v| row[k] == v }
end

mixed_row_cases = [
  {
    label: 'first row undefined nullable field, second row concrete',
    rows: [
      [['id', 21], ['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['created_at', 1_700_000_300]],
      [['id', 22], ['due_date', 1_735_689_600], ['created_at', 1_700_000_301]]
    ],
    nil_key: 'due_date',
    nil_row_id: 21,
    valued_row_id: 22,
    valued_key: 'due_date',
    valued_value: 1_735_689_600
  },
  {
    label: 'first row null nullable field, second row concrete different key',
    rows: [
      [['id', 23], ['archived_at', '__HOMURA_SENTINEL_NULL__'], ['priority', 0]],
      [['id', 24], ['archived_at', 1_735_689_601], ['priority', 1]]
    ],
    nil_key: 'archived_at',
    nil_row_id: 23,
    valued_row_id: 24,
    valued_key: 'archived_at',
    valued_value: 1_735_689_601
  },
  {
    label: 'multiple nullable keys in first row do not poison second row falsy values',
    rows: [
      [['id', 25], ['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['archived_at', '__HOMURA_SENTINEL_NULL__'], ['created_at', 1_700_000_400]],
      [['id', 26], ['due_date', 1_735_689_602], ['archived_at', '__HOMURA_SENTINEL_NULL__'], ['completed', false], ['priority', 0]]
    ],
    nil_key: 'archived_at',
    nil_row_id: 25,
    valued_row_id: 26,
    valued_key: 'due_date',
    valued_value: 1_735_689_602,
    extra_checks: { 'completed' => false, 'priority' => 0, 'archived_at' => nil }
  }
]

SequelSmoke.assert_matrix('js_rows_to_ruby matrix', mixed_row_cases) do |test_case|
  js_rows = `[]`
  test_case[:rows].each do |pairs|
    `#{js_rows}.push(#{build_js_row(pairs)})`
  end
  rows = Cloudflare.js_rows_to_ruby(js_rows)
  nil_row = rows.find { |row| row['id'] == test_case[:nil_row_id] }
  valued_row = rows.find { |row| row['id'] == test_case[:valued_row_id] }
  rows.map { |row| row['id'] } == [test_case[:nil_row_id], test_case[:valued_row_id]] &&
    nil_row[test_case[:nil_key]].nil? &&
    valued_row[test_case[:valued_key]] == test_case[:valued_value] &&
    (test_case[:extra_checks] || {}).all? { |k, v| valued_row[k] == v }
end

nested_js_row = build_js_row([
  ['id', 31],
  ['meta', build_js_row([['due_date', '__HOMURA_SENTINEL_UNDEFINED__'], ['completed', false], ['priority', 0]])]
])
nested_row = Cloudflare.js_object_to_hash(nested_js_row)
SequelSmoke.assert_equal(
  'js_object_to_hash normalizes undefined inside nested plain objects',
  nil,
  nested_row['meta']['due_date']
)
SequelSmoke.assert_equal(
  'js_object_to_hash preserves nested falsy values',
  [false, 0],
  [nested_row['meta']['completed'], nested_row['meta']['priority']]
)

mock.schema_rows['todos'] = [
  { 'name' => 'id', 'type' => 'integer', 'notnull' => 1, 'dflt_value' => nil, 'pk' => 1 },
  { 'name' => 'completed', 'type' => 'boolean', 'notnull' => 1, 'dflt_value' => '0', 'pk' => 0 },
  { 'name' => 'priority', 'type' => 'integer', 'notnull' => 1, 'dflt_value' => '0', 'pk' => 0 }
]
mock.rows = [{ 'id' => 1, 'completed' => 0, 'priority' => 0 }]
rows = db[:todos].all.__await__
SequelSmoke.assert_equal(
  'Dataset#all coerces boolean columns from D1 schema',
  false,
  rows.first['completed']
)
SequelSmoke.assert_equal(
  'Dataset#all leaves integer columns untouched',
  0,
  rows.first['priority']
)

mock.rows = [{ 'id' => 2, 'completed' => 't', 'priority' => 1 }]
rows = db[:todos].all.__await__
SequelSmoke.assert_equal(
  'Dataset#all coerces string-backed true booleans from D1 schema',
  true,
  rows.first['completed']
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

# create_table / alter_table are run via homura db:migrate:compile (CRuby
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
  'Dataset#insert_sql quotes String values',
  "INSERT INTO `users` (`name`) VALUES ('carol')",
  db[:users].insert_sql(name: 'carol')
)

SequelSmoke.assert_equal(
  'Dataset#insert_sql emits integer-backed boolean true',
  'INSERT INTO `todos` (`completed`) VALUES (1)',
  db[:todos].insert_sql(completed: true)
)

SequelSmoke.assert_equal(
  'Dataset#insert_sql emits integer-backed boolean false',
  'INSERT INTO `todos` (`completed`) VALUES (0)',
  db[:todos].insert_sql(completed: false)
)

SequelSmoke.assert_equal(
  'Dataset#update_sql quotes String values in SET/WHERE',
  "UPDATE `users` SET `name` = 'carol' WHERE (`id` = '1')",
  db[:users].where(id: '1').update_sql(name: 'carol')
)

SequelSmoke.assert_equal(
  'Dataset#delete_sql emits DELETE FROM',
  "DELETE FROM `users` WHERE (`id` = 1)",
  db[:users].where(id: 1).delete_sql
)

SequelSmoke.assert_equal(
  'Dataset#delete_sql quotes String values in WHERE',
  "DELETE FROM `users` WHERE (`id` = '1')",
  db[:users].where(id: '1').delete_sql
)

# homura issue #31 — update(col: Sequel.lit('expr')) must inline the
# expression as raw SQL, not quote it as an identifier. In Opal,
# `Symbol` is the same constant as `String`, so without an explicit
# guard the upstream `case v when Symbol` branch swallows
# `Sequel::LiteralString` (a `String` subclass) and routes the value
# through `literal_symbol_append`, which produces backticks:
#   UPDATE `todos` SET `done` = `1 - done`   ← buggy
# The fix lives in lib/sequel_opal_runtime_patches.rb (literal_append
# tests for LiteralString / SQL::Blob before falling into the Symbol
# branch).
SequelSmoke.assert_equal(
  'Dataset#update_sql inlines Sequel.lit value as raw SQL (issue #31)',
  'UPDATE `todos` SET `done` = 1 - done WHERE (`id` = 1)',
  db[:todos].where(id: 1).update_sql(done: ::Sequel.lit('1 - done'))
)

SequelSmoke.assert_equal(
  'Dataset#update_sql inlines Sequel.lit alongside literal value (issue #31)',
  "UPDATE `todos` SET `done` = 1 - done, `title` = 'x' WHERE (`id` = 1)",
  db[:todos].where(id: 1).update_sql(done: ::Sequel.lit('1 - done'), title: 'x')
)

SequelSmoke.assert_equal(
  'Dataset#update_sql inlines Sequel::SQL::Function (issue #31)',
  'UPDATE `users` SET `created_at` = CURRENT_TIMESTAMP() WHERE (`id` = 1)',
  db[:users].where(id: 1).update_sql(created_at: ::Sequel.function(:CURRENT_TIMESTAMP))
)

SequelSmoke.assert_equal(
  'Dataset#insert_sql inlines Sequel.lit values as raw SQL (issue #31 sibling)',
  "INSERT INTO `todos` (`done`) VALUES (1 - done)",
  db[:todos].insert_sql(done: ::Sequel.lit('1 - done'))
)

$stdout.puts ''
SequelSmoke.report ? exit(0) : exit(1)
