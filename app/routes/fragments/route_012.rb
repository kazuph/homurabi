# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 12 — test /test/sequel
get '/test/sequel' do
  content_type 'application/json'
  cases = []
  run = lambda { |label, &blk|
    result = begin
      v = blk.call
      v == false ? { 'pass' => false, 'note' => 'returned false' } : { 'pass' => true }
    rescue ::Exception => e
      { 'pass' => false, 'note' => "#{e.class}: #{e.message[0, 200]}" }
    end
    cases << result.merge('case' => label)
  }

  seq_db = Sequel.connect(adapter: :d1, d1: db)

  run.call('adapter_scheme is :d1') { seq_db.adapter_scheme == :d1 }
  run.call('database_type is :sqlite') { seq_db.database_type == :sqlite }
  run.call('SingleConnectionPool in use') { seq_db.pool.class.name == 'Sequel::SingleConnectionPool' }
  run.call('DB[:users].sql emits SELECT * FROM users') {
    seq_db[:users].sql.to_s == 'SELECT * FROM `users`'
  }
  run.call('DB[:users].where(id: 1).sql emits id = 1') {
    seq_db[:users].where(id: 1).sql.to_s == 'SELECT * FROM `users` WHERE (`id` = 1)'
  }
  run.call('DB[:users].order(:id).limit(5) emits ORDER BY + LIMIT') {
    sql = seq_db[:users].order(:id).limit(5).sql.to_s
    sql.include?('ORDER BY `id`') && sql.include?('LIMIT 5')
  }
  run.call('DB[:users].all hits D1 and returns rows') {
    rows = seq_db[:users].all
    rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) && r['id'] && r['name'] }
  }
  run.call('DB[:users].where(id: 1).first.__await__ returns single row') {
    row = seq_db[:users].where(id: 1).first.__await__
    row.is_a?(Hash) && row['id'].to_i == 1
  }

  pass_count = cases.count { |c| c['pass'] }
  { 'phase' => 12, 'total' => cases.size, 'passed' => pass_count,
    'failed' => cases.size - pass_count, 'cases' => cases }.to_json
end
