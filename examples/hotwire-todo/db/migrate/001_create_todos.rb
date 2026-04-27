# frozen_string_literal: true

Sequel.migration do
  change do
    create_table?(:todos) do
      primary_key :id
      String :title, null: false
      Integer :done, null: false, default: 0
      Integer :created_at, null: false
    end
  end
end
