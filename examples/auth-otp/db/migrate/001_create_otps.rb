# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:otps) do
      primary_key :id
      String :email, null: false
      String :code, null: false
      Integer :expires_at, null: false
      index :email
    end
  end
end
