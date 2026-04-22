# frozen_string_literal: true
# Route fragment 8 — demo /demo/sequel
get '/demo/sequel' do
  content_type 'application/json'
  seq_db = Sequel.connect(adapter: :d1, d1: db)
  rows = seq_db[:users].order(:id).limit(10).all
  { 'rows' => rows, 'adapter' => 'sequel-d1', 'dialect' => 'sqlite' }.to_json
end
