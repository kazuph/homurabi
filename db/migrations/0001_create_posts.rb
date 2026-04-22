# Example Sequel migration — compiled to SQL by bin/homura-migrate
# for consumption by `wrangler d1 migrations apply`. Never loaded
# inside the Opal bundle (migration runner is CRuby-only).
Sequel.migration do
  change do
    create_table(:posts) do
      primary_key :id
      String :title, null: false
      String :body
      Time :created_at, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
