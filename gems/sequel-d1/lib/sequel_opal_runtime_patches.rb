# frozen_string_literal: true
#
# homura patch (Phase 12): runtime monkey-patches for Sequel that
# don't need to fire during the Sequel load — they only matter at
# call time. Codex-reviewed split: compared to in-place edits under
# vendor/sequel/, these overrides are portable and let the vendored
# files stay bit-identical to upstream, simplifying Sequel upgrades.
#
# Loaded AFTER sequel/core (see vendor/sequel.rb), so every class /
# method reference here exists.

require 'sequel/core'

module Sequel
  class Database
    # homura patch (Phase 12): Opal represents Ruby Symbols as
    # native JS strings, so `:table.is_a?(String)` returns true and
    # sends `DB[:users]` down the `fetch(String)` path (which expects
    # verbatim SQL). Explicit Symbol check routes correctly.
    # upstream body: args.first.is_a?(String) ? fetch(*args) : from(*args)
    def [](*args)
      first = args.first
      if first.is_a?(Symbol)
        from(*args)
      elsif first.is_a?(String)
        fetch(*args)
      else
        from(*args)
      end
    end
  end
end

# ------------------------------------------------------------------
# Note: `connection_pool_class` and `Database.load_adapter` cannot be
# externalised — both are reached via interpolated requires that
# Opal's compile-time resolver rejects before runtime code has any
# chance to intercept. They stay patched in-place under
# vendor/sequel/connection_pool.rb and vendor/sequel/database/connecting.rb
# with `# homura patch (Phase 12, LOAD-TIME required)` comments.
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# String-buffer overrides: Sequel's Dataset#sql_string_origin and
# literal_append allocate plain String instances which Opal treats
# as immutable — the `<<` accumulator pattern raises
# NotImplementedError. Replace the allocation sites with
# HomuraSqlBuffer, which implements the Sequel-expected subset of
# String (from lib/sequel_opal_patches.rb).
# ------------------------------------------------------------------
class ::HomuraSqlStringLiteral
  def initialize(value)
    @value = value.to_s
  end

  def sql_literal_append(dataset, sql)
    dataset.literal_string_append(sql, @value)
  end

  def sql_literal_allow_caching?(_dataset)
    true
  end
end

class Sequel::Dataset
  def sql_string_origin
    ::HomuraSqlBuffer.new
  end

  def homura_sql_value(value)
    if value.is_a?(::String) &&
       !value.is_a?(::Sequel::LiteralString) &&
       !value.is_a?(::Sequel::SQL::Blob)
      ::HomuraSqlStringLiteral.new(value)
    else
      value
    end
  end
  private :homura_sql_value

  # upstream literal_append Symbol branch:
  #   l = String.new
  #   literal_symbol_append(l, v)
  #   db.literal_symbol_set(v, l)
  # homura: use Buffer for the append accumulator; cache the
  # rendered String form on the db so subsequent calls hit the
  # cache without re-creating a Buffer.
  alias_method :__homura_orig_literal_append, :literal_append
  def literal_append(sql, v)
    if v.is_a?(::HomuraSqlStringLiteral)
      v.sql_literal_append(self, sql)
    elsif v.is_a?(Symbol)
      if skip_symbol_cache?
        literal_symbol_append(sql, v)
      else
        unless l = db.literal_symbol(v)
          l = sql_string_origin
          literal_symbol_append(l, v)
          db.literal_symbol_set(v, l.to_s)
        end
        sql << l
      end
    else
      __homura_orig_literal_append(sql, v)
    end
  end

  alias_method :__homura_orig_update_sql_values_hash, :update_sql_values_hash
  def update_sql_values_hash(sql, values)
    values = values.each_with_object({}) { |(k, v), acc| acc[k] = homura_sql_value(v) }
    __homura_orig_update_sql_values_hash(sql, values)
  end

  alias_method :__homura_orig__insert_values_sql, :_insert_values_sql
  def _insert_values_sql(sql, values)
    if values.is_a?(Array)
      values = values.map { |v| homura_sql_value(v) }
    end
    __homura_orig__insert_values_sql(sql, values)
  end
end

class Sequel::SQL::BooleanExpression
  class << self
    alias_method :__homura_orig_from_value_pair, :from_value_pair

    def from_value_pair(l, r)
      if r.is_a?(::String) &&
         !r.is_a?(::Sequel::LiteralString) &&
         !r.is_a?(::Sequel::SQL::Blob)
        r = ::HomuraSqlStringLiteral.new(r)
      end
      __homura_orig_from_value_pair(l, r)
    end
  end
end
