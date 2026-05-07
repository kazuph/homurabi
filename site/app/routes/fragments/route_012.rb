# frozen_string_literal: true
# Route fragment 12 — test /test/sequel
get("/test/sequel") do
  content_type("application/json")
  cases = []
  run = lambda do |label, &blk|
    result = begin
      v = blk.call
      if v == false
        {"pass" => false, "note" => "returned false"}
      else
        {"pass" => true}
      end

    rescue ::Exception => e
      {"pass" => false, "note" => "#{e.class}: #{e.message[0, 200]}"}
    end

    cases << result.merge("case" => label)
  end

  seq_db = Sequel.connect(adapter: :d1, d1: db)

  run.call("adapter_scheme is :d1") { seq_db.adapter_scheme == :d1 }
  run.call("database_type is :sqlite") { seq_db.database_type == :sqlite }
  run.call("SingleConnectionPool in use") do
    seq_db.pool.class.name == "Sequel::SingleConnectionPool"
  end

  run.call("DB[:users].sql emits SELECT * FROM users") do
    seq_db[:users].sql.to_s == "SELECT * FROM `users`"
  end

  run.call("DB[:users].where(id: 1).sql emits id = 1") do
    seq_db[:users].where(id: 1).sql.to_s == "SELECT * FROM `users` WHERE (`id` = 1)"
  end

  run.call("DB[:users].order(:id).limit(5) emits ORDER BY + LIMIT") do
    sql = seq_db[:users].order(:id).limit(5).sql.to_s
    sql.include?("ORDER BY `id`") && sql.include?("LIMIT 5")
  end

  run.call("DB[:users].all hits D1 and returns rows") do
    rows = seq_db[:users].all
    rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) && r["id"] && r["name"] }
  end

  run.call("DB[:users].where(id: 1).first returns single row") do
    row = seq_db[:users].where(id: 1).first
    row.is_a?(Hash) && row["id"].to_i == 1
  end

  pass_count = cases.count { |c| c["pass"] }
  {
    "phase" => 12,
    "total" => cases.size,
    "passed" => pass_count,
    "failed" => cases.size - pass_count,
    "cases" => cases
  }.to_json
end
