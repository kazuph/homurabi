# frozen_string_literal: true
# Route fragment 10 — posts /posts
get '/posts' do
  content_type 'application/json'
  seq_db = Sequel.connect(adapter: :d1, d1: db)
  rows = seq_db[:posts].order(Sequel.desc(:id)).limit(20).all
  { 'count' => rows.size, 'posts' => rows }.to_json
end
