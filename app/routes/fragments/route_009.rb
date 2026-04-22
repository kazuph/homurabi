# await: true
# frozen_string_literal: true
# Route fragment 9 — demo /demo/sequel/sql
get '/demo/sequel/sql' do
  content_type 'application/json'
  seq_db = Sequel.connect(adapter: :d1, d1: db)
  ds = seq_db[:users].where(active: true).order(:name).limit(10)
  { 'sql' => ds.sql.to_s, 'adapter' => 'sequel-d1' }.to_json
end
