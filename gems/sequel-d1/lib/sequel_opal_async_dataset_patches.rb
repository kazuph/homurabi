# frozen_string_literal: true
# await: true
#
# homura patch (Phase 12): async Dataset action overrides.
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
    # homura: fetch_rows is async (D1 adapter awaits the Promise
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
    # homura: yield(a) returns a Promise when the caller block
    # crosses the D1 adapter's async boundary (Dataset#all's block
    # is async-compiled). Await so `a` is populated before post_load.
    def _all(block)
      a = []
      yield(a).__await__
      post_load(a)
      a.each(&block) if block
      a
    end

    # upstream: with_sql_each(sql){|r| yield r}; self (sync, but fetch_rows
    # returns a Promise under the D1 adapter, so the block body doesn't
    # run before the caller's sync flow resumes — the Promise is dropped).
    # homura: reopen with `.__await__` so the async fetch_rows resolves
    # before this method returns. Required for #first / #with_sql_first /
    # #with_sql_single_value which expect the block to have fired.
    def with_sql_each(sql)
      if rp = row_proc
        _with_sql_dataset.fetch_rows(sql){|r| yield rp.call(r)}.__await__
      else
        _with_sql_dataset.fetch_rows(sql){|r| yield r}.__await__
      end
      self
    end

    # upstream: with_sql_each(sql){|r| return r}; nil
    # homura: capture first row without `return`; callers always
    # clone with limit(1) so the no-break form is equivalent. Needs
    # with_sql_each to actually await its fetch_rows (see above).
    def with_sql_first(sql)
      result = nil
      # with_sql_each is async now (awaits fetch_rows internally); we must
      # await here so `result` is populated before returning.
      (with_sql_each(sql) do |r|
        result = r if result.nil?
      end).__await__
      result
    end

    # upstream: single_value_ds.each{|r| r.each{|_, v| return v}}; nil
    # homura: capture first value using sentinel flag. Relies on each
    # awaiting the D1 Promise chain.
    def single_value
      value = nil
      found = false
      # each is async (patched in this file); must await.
      (single_value_ds.each do |r|
        next if found
        r.each do |_, v|
          next if found
          value = v
          found = true
        end
      end).__await__
      found ? value : nil
    end

    # upstream: if r = with_sql_first(sql); r.each{|_, v| return v}; end
    # homura: same capture-first-value pattern via sentinel.
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

    # Sqlite3-ruby / homura-runtime D1Database compatibility shim.
    # Mirrors the `db.get_first_row(sql, [params])` shape exposed by
    # `Cloudflare::D1Database` so code that mixes the two layers (or
    # follows that documentation style) works on `Sequel::Dataset` too.
    #
    #   db[:users].where(id: 1).get_first_row    # → Hash or nil
    #   db[:users].get_first_row('id = ?', 1)    # accepts the same
    #                                              # params as #where.
    #
    # Implemented as a thin wrapper over `Dataset#first`, which already
    # crosses the async boundary correctly via the patches in this file.
    def get_first_row(*conds, &block)
      conds.empty? && block.nil? ? first : first(*conds, &block)
    end
  end
end
