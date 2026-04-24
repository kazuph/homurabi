# frozen_string_literal: true

require 'cloudflare_workers/async_registry'

CloudflareWorkers::AsyncRegistry.register_async_source do
  helper_factory :db, 'Sequel::D1::Database'
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
end
