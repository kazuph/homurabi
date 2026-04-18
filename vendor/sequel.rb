# frozen_string_literal: true
# backtick_javascript: true
#
# homurabi patch: Phase 12 — vendored entry for Sequel v5.103.0
# (https://github.com/jeremyevans/sequel). This file replaces the
# upstream `lib/sequel.rb` (which only does `require_relative
# 'sequel/model'`) because on Cloudflare Workers we deliberately skip
# Sequel::Model (eval-heavy, not needed for Dataset DSL in Phase 12).
#
# Load order:
#   1. sequel_opal_patches — Mutex/Thread/class_eval shims
#      (must run BEFORE any vendor/sequel/*.rb is required so the
#      class bodies see the shims).
#   2. vendor/sequel/core — sequel/{sql, dataset, database, ...}.
#   3. Sequel.synchronize override (SingleConnectionPool, no-op).
#   4. D1 adapter is loaded on demand via Sequel.connect('d1://')
#      → vendor/sequel/database/connecting.rb calls
#      `require "sequel/adapters/d1"` which resolves to our custom
#      lib/sequel/adapters/d1.rb (Opal build -I lib -I vendor resolves
#      lib/ first).
#
# Phase 12 scope: Dataset DSL only. Sequel::Model, plugins, and most
# extensions are deliberately NOT required.

require 'sequel_opal_patches'
require 'sequel/core'
# Eager-load every connection pool shape that is Opal-safe (no
# Mutex/Thread/ConditionVariable at runtime). Upstream's
# connection_pool.rb does `require_relative "connection_pool/#{pc}"`
# which Opal cannot resolve statically, so we pre-require here and
# delegate lookup via POOL_CLASS_MAP. Threaded pools are deliberately
# omitted — they would load Mutex machinery the Worker isolate
# cannot honor.
require 'sequel/connection_pool/single'
require 'sequel/connection_pool/sharded_single'

# homurabi 3-layer patch split (Codex-reviewed):
#   1. vendor/sequel/**/*.rb   — only load-time / class-body
#      metaprogramming patches (class_eval(String) → define_method,
#      Sequel.require + Mutex/Thread shims in core.rb). These
#      cannot be externalised because they run during class body.
#   2. lib/sequel_opal_runtime_patches.rb — sync runtime overrides
#      (Database#[] Symbol check, connection_pool_class, load_adapter,
#      sql_string_origin / literal_append).
#   3. lib/sequel_opal_async_dataset_patches.rb — `# await: true`
#      reopen of Dataset for #each / #_all / #with_sql_first /
#      #single_value / #with_sql_single_value.
# Load order matters: (2) and (3) both need Sequel::Dataset open.
require 'sequel_opal_runtime_patches'
require 'sequel_opal_async_dataset_patches'

# Sequel.synchronize already delegates to @data_mutex.synchronize, and
# the homurabi Mutex shim (sequel_opal_patches.rb) resolves that to a
# plain yield — no override needed here.

# SingleConnectionPool is the only pool shape compatible with Opal's
# Thread model. Make it the hard default for Workers builds so no
# user ever accidentally instantiates ThreadedConnectionPool (which
# references Mutex/ConditionVariable and would crash at first hold).
module ::Sequel
  class Database
    private

    if method_defined?(:connection_pool_default_options, false) ||
       private_method_defined?(:connection_pool_default_options, false)
      remove_method(:connection_pool_default_options)
    end
    def connection_pool_default_options
      { pool_class: :single }
    end
  end
end

# Eagerly load the D1 adapter — in Workers there is no other DB to
# connect to, and lazy load-via-require would require runtime
# filesystem access that Opal does not support.
require 'sequel/adapters/d1'
