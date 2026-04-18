# frozen_string_literal: true
# backtick_javascript: true
#
# homurabi patch: Phase 12 — Sequel v5.103.0 Opal/Workers compatibility shims.
#
# Sequel's core path assumes CRuby Mutex/Thread and `class_eval("def x; end")`
# runtime code generation. Cloudflare Workers forbids runtime eval; Opal's
# stdlib does not ship a full Mutex/Thread implementation.
#
# Two classes of fix:
#   1. `class_eval(String)` → done **in-place** in vendor/sequel/*.rb,
#      each patched with a `# homurabi patch:` comment marking the
#      upstream line that was rewritten to `define_method(&block)`.
#      See vendor/sequel/sql.rb, vendor/sequel/dataset/query.rb, etc.
#   2. Runtime shims (Mutex, Thread.current) live here, loaded BEFORE
#      vendor/sequel.rb — which is the homurabi entry point that
#      requires 'sequel/core' after installing these shims.
#
# Scope: Phase 12 ships Dataset DSL + D1 adapter + migration CLI.
# Sequel::Model and most plugins are NOT bundled into the Workers
# runtime. Shims are therefore limited to the core/Database/Dataset
# path; Model-specific patches would belong in a future phase.

# -----------------------------------------------------------------
# Mutex — Sequel core.rb (`@data_mutex = Mutex.new`) and adapter
# registration (`Sequel.synchronize`) reference Mutex. With a
# Workers isolate + SingleConnectionPool the Mutex never has real
# contention. We install a no-op Mutex if Opal's stdlib didn't.
# -----------------------------------------------------------------
unless defined?(::Mutex)
  class ::Mutex
    def synchronize
      yield
    end

    def lock
      self
    end

    def unlock
      self
    end

    def try_lock
      true
    end

    def locked?
      false
    end
  end
end

# -----------------------------------------------------------------
# Thread.current — Sequel database/transactions.rb references
# `Thread.current.status` to detect `Thread#kill` aborts. Workers
# never kills threads, so we return a fixed stub with status=='run'.
# Opal 1.8.3.rc1 does ship a minimal Thread class; only patch if
# missing to avoid fighting Opal.
# -----------------------------------------------------------------
unless defined?(::Thread) && ::Thread.respond_to?(:current) && (::Thread.current.respond_to?(:status) rescue false)
  module ::HomurabiThreadStub
    class FauxThread
      def status
        'run'
      end

      def [](k)
        (@__hash ||= {})[k]
      end

      def []=(k, v)
        (@__hash ||= {})[k] = v
      end

      def abort_on_exception
        false
      end
    end

    INSTANCE = FauxThread.new
  end

  unless defined?(::Thread)
    class ::Thread; end
  end

  class ::Thread
    class << self
      def current
        ::HomurabiThreadStub::INSTANCE
      end

      def list
        [current]
      end
    end
  end
end

# -----------------------------------------------------------------
# Fiber.current placeholder — async_thread_pool extension references
# it, but we never load that extension. Defensive stub in case
# transitive requires pull it in.
# -----------------------------------------------------------------
unless defined?(::Fiber)
  class ::Fiber
    def self.current
      nil
    end
  end
end

# -----------------------------------------------------------------
# bigdecimal — Sequel core.rb:3 does `require 'bigdecimal'` at top.
# Opal 1.8.3.rc1 doesn't ship BigDecimal. We never actually use it
# in the Dataset path for SQLite/D1 (which uses Integer/Float only),
# so install a Float-backed stand-in that keeps the require from
# raising LoadError.
# -----------------------------------------------------------------
unless defined?(::BigDecimal)
  class ::BigDecimal < ::Numeric
    def self.new(v, _precision = nil)
      new_from(v)
    end

    def self.new_from(v)
      alloc = allocate
      alloc.instance_variable_set(:@v, v.to_f)
      alloc
    end

    def to_f
      @v
    end

    def to_s(*)
      @v.to_s
    end

    def ==(other)
      other.respond_to?(:to_f) && to_f == other.to_f
    end
  end

  module ::Kernel
    def BigDecimal(v, _precision = nil)
      ::BigDecimal.new_from(v)
    end
    module_function :BigDecimal
  end
end

# -----------------------------------------------------------------
# Set — Opal ships a partial Set implementation. Sequel uses
# Set#add, Set#include?, Set.new(array). All supported. No patch.
# -----------------------------------------------------------------

# -----------------------------------------------------------------
# class_eval(String) guard was removed because it caused a
# recursive alias_method loop during Opal load. All class_eval(String)
# sites Sequel emits are patched **in-place** in the vendored file
# (see `# homurabi patch:` comments in vendor/sequel/sql.rb,
# vendor/sequel/dataset/query.rb, vendor/sequel/dataset/sql.rb,
# vendor/sequel/timezones.rb). If a future Sequel upgrade introduces
# a new class_eval(String) site we missed, the first call to that
# method will hit Workers' "Code generation disallowed" rule and
# raise at runtime — which is the signal to add another patch.
# -----------------------------------------------------------------

# -----------------------------------------------------------------
# String#<< — Opal's corelib disables this on purpose because JS
# strings are immutable primitives, and Opal wraps them as Ruby
# String proxies. Sequel's SQL builder appends chunks with `<<` on
# a sql_string_origin result. We can't make JS strings mutable, so
# re-open String and implement `<<` that *reassigns the internal
# char payload using `String#replace`* — which Opal also raises on,
# but we can sidestep by doing it at the JS layer directly.
#
# Actually: JS primitives are truly immutable; the whole premise is
# impossible without changing caller variables. Instead, we make
# Sequel use a mutable-buffer wrapper at sql_string_origin, and
# provide the same `<<` / `to_s` / etc. surface. See the
# `Sequel::SqlStringBuilder` class defined below; Sequel's
# `sql_string_origin` (vendored file, patched in-place) is updated
# to return a new instance of it.
# -----------------------------------------------------------------

# A mutable string-like buffer used by Sequel's SQL generator so it
# can `buf << 'SELECT '` without hitting Opal's immutable-string
# NotImplementedError. Exposes the subset of String methods that
# Sequel actually calls on the sql accumulator.
#
# freeze / frozen? follow Ruby semantics: after `freeze` returns,
# every mutating method (`<<`, `concat`, `sub`, `gsub`, `chomp!`,
# `slice!`, `clear`) raises FrozenError, matching what native
# String does. This avoids silent mutation bugs if Sequel (or a
# future patch) freezes a cached SQL buffer.
class ::HomurabiSqlBuffer
  def initialize(init = '')
    @chunks = init.empty? ? [] : [init.to_s]
    @frozen = false
  end

  def <<(other)
    ensure_not_frozen!
    @chunks << other.to_s
    self
  end
  alias_method :concat, :<<

  def to_s
    @chunks.join
  end
  alias_method :to_str, :to_s

  def length
    to_s.length
  end
  alias_method :size, :length

  def empty?
    @chunks.empty? || @chunks.all? { |c| c.to_s.empty? }
  end

  def [](*args)
    to_s[*args]
  end

  def ==(other)
    to_s == other.to_s
  end

  # Return Buffer instead of raw String so subsequent `<<` chains
  # don't land on Opal's immutable String. Callers that compare
  # against String literals still work because of `==` (delegates
  # to `to_s`).
  def sub(*args, &block)
    ensure_not_frozen!
    s = to_s.sub(*args, &block)
    @chunks = [s]
    self
  end

  def gsub(*args, &block)
    ensure_not_frozen!
    s = to_s.gsub(*args, &block)
    @chunks = [s]
    self
  end

  def include?(other)
    to_s.include?(other.to_s)
  end

  def end_with?(*args)
    to_s.end_with?(*args)
  end

  def start_with?(*args)
    to_s.start_with?(*args)
  end

  def chomp!(*args)
    ensure_not_frozen!
    s = to_s.chomp(*args)
    @chunks = [s]
    self
  end

  def slice!(*args)
    ensure_not_frozen!
    s = to_s
    removed = s.slice!(*args)
    @chunks = [s]
    removed
  end

  def clear
    ensure_not_frozen!
    @chunks = []
    self
  end

  def freeze
    @frozen = true
    self
  end

  def frozen?
    !!@frozen
  end

  def dup
    ::HomurabiSqlBuffer.new(to_s)
  end

  def inspect
    to_s.inspect
  end

  def hash
    to_s.hash
  end

  def eql?(other)
    to_s.eql?(other.respond_to?(:to_s) ? other.to_s : other)
  end

  private

  def ensure_not_frozen!
    raise ::FrozenError, "can't modify frozen HomurabiSqlBuffer: #{to_s.inspect}" if @frozen
  end

  public

  def method_missing(name, *args, &block)
    s = to_s
    if s.respond_to?(name)
      s.public_send(name, *args, &block)
    else
      super
    end
  end

  def respond_to_missing?(name, include_private = false)
    ''.respond_to?(name, include_private) || super
  end
end

# -----------------------------------------------------------------
# `Sequel.synchronize` shim — registered on the Sequel module after
# core.rb loads. With SingleConnectionPool + no real threads,
# synchronization reduces to plain yield. This is safe because:
#   - D1 adapter's `execute` resolves a JS Promise synchronously
#     via Opal's `.__await__`, so no Ruby-side concurrency exists.
#   - Workers isolates don't run Ruby-level threads.
# -----------------------------------------------------------------
# Applied via vendor/sequel.rb AFTER core.rb loads; cannot override
# here because the ::Sequel module doesn't exist yet.

# -----------------------------------------------------------------
# Kernel#gem — Sequel's version.rb may call `gem 'sequel'` to pin
# the version. Opal has no Bundler; no-op.
# -----------------------------------------------------------------
module ::Kernel
  unless respond_to?(:gem) || private_method_defined?(:gem)
    def gem(*_args)
      nil
    end
    module_function :gem
    private :gem
  end
end
