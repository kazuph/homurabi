# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# homurabi patch: Phase 12 — Cloudflare D1 adapter for Sequel.
#
# Sequel's upstream `sequel/adapters/sqlite.rb` drives sqlite3-ruby
# (a C extension that speaks to a file-backed SQLite via synchronous
# FFI). Cloudflare D1 is SQLite-backed but exposed as an async JS
# binding (`env.DB.prepare(sql).bind(...).all()`). We wrap the JS
# binding in `.__await__` so Ruby callers get a familiar synchronous-
# looking API, then piggyback on Sequel's shared/sqlite dialect for
# all the dialect-specific SQL generation (PRAGMA, LIMIT, etc.).
#
# Usage (typical in a Sinatra route):
#
#   get '/demo/sequel' do
#     db = Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])
#     users = db[:users].where(active: true).order(:name).limit(10).all.__await__
#     json users
#   end
#
# The `:d1` option must be a `Cloudflare::D1Database` instance; it is
# wired per-request from `env['cloudflare.DB']`. Workers isolates
# hold the binding for the duration of the request, so one
# Sequel::D1::Database per request is fine (SingleConnectionPool
# keeps overhead minimal).
#
# Async boundary: Dataset#all / #first / #count are synchronous from
# Ruby's point of view but transitively call `fetch_rows` →
# `execute` → `.__await__(env.DB.prepare...)`. Callers in Sinatra
# routes append `.__await__` to the Dataset call to resolve the
# Promise, matching the D1/KV/R2 idiom already used in Phase 3-10.

require 'cloudflare_workers'
require 'sequel/adapters/shared/sqlite'

module Sequel
  module D1
    # Exception raised when the JS binding reports a SQLite error or
    # when the adapter detects a contract violation (e.g. missing
    # meta field expected from D1's run() response).
    class Error < ::Sequel::Error
      attr_reader :sql, :meta

      def initialize(message, sql: nil, meta: nil)
        super(message)
        @sql = sql
        @meta = meta
      end
    end

    class MissingMetaError < Error; end

    # Thin wrapper around a Cloudflare::D1Database. Backed by Opal
    # `.__await__` resolution so Ruby callers see a synchronous
    # method signature. One instance per Sequel::D1::Database;
    # SingleConnectionPool keeps this at exactly one "connection"
    # per Database instance.
    class Connection
      def initialize(d1_binding)
        @binding = d1_binding
      end

      # Execute a write (INSERT/UPDATE/DELETE/DDL). Returns a Hash
      # with :last_insert_rowid and :changes keys so Sequel
      # execute_insert / execute_dui can pass them back.
      def run(sql, bindings = [])
        # Always stringify — Sequel's SQL builder uses
        # HomurabiSqlBuffer (buffer wrapper for Opal), and D1's
        # prepare() validator (Zod) rejects non-string inputs with
        # "Expected string, received object".
        stmt = @binding.prepare(sql.to_s)
        stmt = stmt.bind(*bindings) unless bindings.empty?
        stmt.run
      end

      def query(sql, bindings = [])
        stmt = @binding.prepare(sql.to_s)
        stmt = stmt.bind(*bindings) unless bindings.empty?
        stmt.all
      end

      def exec(sql)
        run(sql.to_s, [])
      end

      # Sequel's transaction machinery calls `conn.execute(sql)` to
      # emit BEGIN / COMMIT / ROLLBACK statements directly. Forward
      # these to `run` so the full TX lifecycle reaches D1.
      def execute(sql, bindings = [])
        run(sql, bindings)
      end

      def close
        # JS binding is isolate-scoped; nothing to close.
        true
      end
    end

    class Database < ::Sequel::Database
      include ::Sequel::SQLite::DatabaseMethods
      set_adapter_scheme :d1

      # Accepts connection via Hash (the path routes use) OR a
      # `d1://` URL for migrator-side CLI usage (no D1 binding
      # available there; raises at connect time if actually used).
      def self.options_from_uri(uri)
        { binding_name: uri.host.to_s }
      end

      def connect(_server)
        d1_binding = @opts[:d1] || @opts[:database]
        unless d1_binding
          raise Error, "Sequel D1 adapter requires a :d1 option pointing at a Cloudflare::D1Database. " \
                       "Example: Sequel.connect(adapter: :d1, d1: env['cloudflare.DB'])"
        end
        Connection.new(d1_binding)
      end

      # -----------------------------------------------------------
      # Sequel execute API (Database#execute is the core plumbing
      # Dataset#all / #insert / #update / #delete all funnel through)
      # -----------------------------------------------------------

      def execute(sql, opts = OPTS, &block)
        # Materialise rows via await. The inner synchronize block
        # awaits the D1 Promise; we await synchronize's Promise
        # result here so callers see a plain Array. D1-side failures
        # (Promise rejection / Cloudflare::D1Error / any JS exception
        # bubbled via Opal) are caught and re-raised as Sequel::D1::Error
        # with the offending SQL attached so Sequel's error handling
        # path classifies them via database_error_classes.
        rows = synchronize(opts[:server]) do |conn|
          conn.query(sql, Array(opts[:arguments])).__await__
        end.__await__
        rows.each(&block) if block
        rows
      rescue Error
        raise
      rescue ::Exception => e
        raise wrap_d1_error(e, sql, 'execute')
      end

      def execute_insert(sql, opts = OPTS)
        synchronize(opts[:server]) do |conn|
          raw = conn.run(sql, Array(opts[:arguments])).__await__
          d1_meta_value(raw, 'last_row_id')
        end.__await__
      rescue Error
        raise
      rescue ::Exception => e
        raise wrap_d1_error(e, sql, 'execute_insert')
      end

      def execute_dui(sql, opts = OPTS)
        synchronize(opts[:server]) do |conn|
          raw = conn.run(sql, Array(opts[:arguments])).__await__
          d1_meta_value(raw, 'changes')
        end.__await__
      rescue Error
        raise
      rescue ::Exception => e
        raise wrap_d1_error(e, sql, 'execute_dui')
      end

      private

      # D1 run() result shape varies across runtime versions:
      #   { 'success' => true, 'meta' => { 'last_row_id' => 7, 'changes' => 1 } }
      #   or { 'last_row_id' => 7, 'changes' => 1 } (older shims)
      # Raise MissingMetaError if the key isn't present in either
      # shape; silently returning nil would mask real failures
      # (e.g. INSERT succeeded but last_row_id is not reported —
      # that's a contract violation worth surfacing).
      def d1_meta_value(raw, key)
        unless raw.is_a?(::Hash)
          raise MissingMetaError, "D1 run() returned non-Hash #{raw.class}: #{raw.inspect[0, 120]}"
        end
        meta = raw['meta'].is_a?(::Hash) ? raw['meta'] : raw
        value = meta[key] || meta[key.to_sym]
        if value.nil?
          raise MissingMetaError.new(
            "D1 run() meta missing '#{key}'. Available keys: #{meta.keys.inspect}",
            meta: meta
          )
        end
        value
      end

      # Convert any non-Sequel failure raised from inside an D1 await
      # site into a Sequel::D1::Error. `database_error_classes`
      # returns [Error], so Sequel's upstream error-handling path
      # recognises the wrapped failure and attaches the SQL for
      # debuggability. Preserves the original message prefix so the
      # underlying JS / Cloudflare::D1Error detail is not lost.
      def wrap_d1_error(exc, sql, op)
        Error.new(
          "D1 #{op} failed: #{exc.class}: #{exc.message}",
          sql: sql.to_s,
          meta: (exc.respond_to?(:meta) ? exc.meta : nil)
        )
      end

      public

      def execute_ddl(sql, opts = OPTS)
        synchronize(opts[:server]) do |conn|
          conn.exec(sql).__await__
        end.__await__
        nil
      rescue Error
        raise
      rescue ::Exception => e
        raise wrap_d1_error(e, sql, 'execute_ddl')
      end

      # -----------------------------------------------------------
      # Schema introspection — D1 supports most SQLite PRAGMAs
      # (table_info, index_list, foreign_key_list). Shared sqlite
      # DatabaseMethods#schema_parse_table issues these as normal
      # SELECT statements, which Sequel routes through execute().
      # No override needed at this phase — if a PRAGMA fails we'll
      # hit a clear Error and can add a fallback then.
      # -----------------------------------------------------------

      private

      def adapter_initialize
        @single_threaded = true
        @default_transaction_mode = :deferred
        @opts[:single_threaded] = true
      end

      def database_error_classes
        [Error]
      end

      def disconnect_error?(exception, _opts = OPTS)
        false
      end

      def connection_pool_default_options
        { pool_class: :single }
      end

      def dataset_class_default
        ::Sequel::D1::Dataset
      end
    end

    # Dataset — delegated to shared sqlite dialect entirely.
    class Dataset < ::Sequel::Dataset
      include ::Sequel::SQLite::DatasetMethods

      # fetch_rows on the D1 adapter materialises the full result
      # set via `execute` (which `.__await__`s the D1 Promise) and
      # yields each row synchronously to the caller's block. Keeping
      # the yield loop sync-only is critical: Opal's async-function
      # compiler cannot propagate Ruby block-exit throws
      # (break / next / return) across an `await` boundary —
      # trying results in LocalJumpError. Upstream Sequel's
      # with_sql_first / single_value rely on `break`/`return` from
      # inside this loop, so we keep it strictly sync here.
      def fetch_rows(sql, &block)
        # Opal compiles this method to an async function because of
        # `.__await__`. After the await completes we hold a plain
        # Array, so the each below iterates synchronously — Ruby
        # block-exit throws (break/next/return) bind to this local
        # each rather than to some outer async continuation.
        rows = execute(sql).__await__
        rows.each(&block)
      end
    end
  end
end
