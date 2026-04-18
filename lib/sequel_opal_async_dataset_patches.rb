# frozen_string_literal: true
# await: true
#
# homurabi patch (Phase 12): async Dataset action overrides.
#
# Upstream Sequel's Dataset#_all / #with_sql_first / #single_value /
# #with_sql_single_value use synchronous `return v` / `break` from
# inside yield blocks to short-circuit row collection. On
# Cloudflare Workers the D1 adapter must await a Promise inside
# #fetch_rows, so any async boundary crossed by those throwers
# turns into LocalJumpError at runtime.
#
# This file reopens Sequel::Dataset with the `# await: true` magic
# comment, replacing those methods with capture-then-drop variants
# that cross async boundaries cleanly. Codex-reviewed rationale:
# keeping these overrides OUT of vendor/sequel/dataset/actions.rb
# lets that vendored file stay bit-identical to upstream for the
# non-async sites — simpler to rebase when bumping Sequel.
#
# Load order (see vendor/sequel.rb): required AFTER sequel/core,
# so the reopening hits the already-loaded Dataset class.
#
# Each method keeps upstream semantics visible (same return value
# shape, same block contract); only the control-flow shape differs.

require 'sequel/core'

module Sequel
  class Dataset
    # upstream each:
    #   if rp = row_proc; fetch_rows(select_sql){|r| yield rp.call(r)}
    #   else              fetch_rows(select_sql){|r| yield r}
    #   end; self
    # homurabi: fetch_rows is async (D1 adapter awaits the Promise
    # chain). If we leave each sync, the block passed to fetch_rows
    # never runs before each returns. Await fetch_rows to let the
    # inner block fire first.
    def each
      if rp = row_proc
        fetch_rows(select_sql){|r| yield rp.call(r)}.__await__
      else
        fetch_rows(select_sql){|r| yield r}.__await__
      end
      self
    end

    # upstream: a = []; yield a; post_load(a); a.each(&block) if block; a
    # homurabi: yield(a) returns a Promise when the caller block
    # crosses the D1 adapter's async boundary (Dataset#all's block
    # is async-compiled). Await so `a` is populated before post_load.
    def _all(block)
      a = []
      yield(a).__await__
      post_load(a)
      a.each(&block) if block
      a
    end

    # upstream: with_sql_each(sql){|r| return r}; nil
    # homurabi: capture first row without `return`; callers always
    # clone with limit(1) so the no-break form is equivalent.
    def with_sql_first(sql)
      result = nil
      with_sql_each(sql) do |r|
        result = r if result.nil?
      end
      result
    end

    # upstream: single_value_ds.each{|r| r.each{|_, v| return v}}; nil
    # homurabi: capture first value using sentinel flag.
    def single_value
      value = nil
      found = false
      single_value_ds.each do |r|
        next if found
        r.each do |_, v|
          next if found
          value = v
          found = true
        end
      end
      found ? value : nil
    end

    # upstream: if r = with_sql_first(sql); r.each{|_, v| return v}; end
    # homurabi: same capture-first-value pattern via sentinel.
    def with_sql_single_value(sql)
      if r = with_sql_first(sql)
        value = nil
        captured = false
        r.each do |_, v|
          next if captured
          value = v
          captured = true
        end
        value
      end
    end
  end
end
