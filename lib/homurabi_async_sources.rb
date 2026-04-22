# frozen_string_literal: true

# Homurabi-specific async accessor registrations for Phase 17.5 Auto-Await.
# These map the env binding names used in wrangler.toml to their
# Cloudflare wrapper class names so the analyzer can taint them.

require 'cloudflare_workers/async_registry'

CloudflareWorkers::AsyncRegistry.register_async_source do
  async_accessor :env, :DB, 'Cloudflare::D1Database'
  async_accessor :env, :KV, 'Cloudflare::KVNamespace'
  async_accessor :env, :BUCKET, 'Cloudflare::R2Bucket'
  async_accessor :env, :AI, 'Cloudflare::AI'
  async_accessor :env, :SEND_EMAIL, 'Cloudflare::Email'
  async_accessor :env, :CACHE, 'Cloudflare::Cache'
  async_accessor :env, :JOBS_QUEUE, 'Cloudflare::Queue'
  async_accessor :env, :DO_COUNTER, 'Cloudflare::DurableObjectNamespace'

  async_accessor :env, :'cloudflare.DB', 'Cloudflare::D1Database'
  async_accessor :env, :'cloudflare.KV', 'Cloudflare::KVNamespace'
  async_accessor :env, :'cloudflare.BUCKET', 'Cloudflare::R2Bucket'
  async_accessor :env, :'cloudflare.AI', 'Cloudflare::AI'
  async_accessor :env, :'cloudflare.SEND_EMAIL', 'Cloudflare::Email'
  async_accessor :env, :'cloudflare.CACHE', 'Cloudflare::Cache'
  async_accessor :env, :'cloudflare.JOBS_QUEUE', 'Cloudflare::Queue'
  async_accessor :env, :'cloudflare.DO_COUNTER', 'Cloudflare::DurableObjectNamespace'

  helper_factory :db, 'Cloudflare::D1Database'
  helper_factory :kv, 'Cloudflare::KVNamespace'
  helper_factory :bucket, 'Cloudflare::R2Bucket'
  helper_factory :ai_binding, 'Cloudflare::AI'
  helper_factory :send_email, 'Cloudflare::Email'
  helper_factory :cache, 'Cloudflare::Cache'
  helper_factory :jobs_queue, 'Cloudflare::Queue'
  helper_factory :do_counter, 'Cloudflare::DurableObjectNamespace'

  taint_return 'Sequel', :connect, 'Sequel::D1::Database'
  async_method 'Sequel::D1::Database', :execute
  async_method 'Sequel::D1::Database', :execute_insert
  async_method 'Sequel::D1::Database', :execute_ddl
  taint_return 'Sequel::D1::Database', :[], 'Sequel::Dataset'

  async_method 'Sequel::Dataset', :insert
  async_method 'Sequel::Dataset', :update
  async_method 'Sequel::Dataset', :delete
  async_method 'Sequel::Dataset', :all
  async_method 'Sequel::Dataset', :first
  async_method 'Sequel::Dataset', :count
  async_method 'Sequel::Dataset', :transaction
  taint_return 'Sequel::Dataset', :where, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :order, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :limit, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :select, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :from, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :join, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :left_join, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :group, 'Sequel::Dataset'
  taint_return 'Sequel::Dataset', :having, 'Sequel::Dataset'

  async_method 'Cloudflare::HTTP', :fetch
  async_method 'Net::HTTP', :get
  async_method 'Net::HTTP', :get_response
  async_method 'Net::HTTP', :post_form

  async_method 'JWT', :encode
  async_method 'JWT', :decode
end
