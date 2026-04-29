# frozen_string_literal: true
# Route fragment 52 — demo /phase11a/cleanup
post '/phase11a/cleanup' do
  content_type 'application/json'
  unless foundations_demos_enabled?
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURA_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  if bucket.nil?
    status 503
    next({ 'error' => 'R2 binding not configured' }.to_json)
  end
  rows = bucket.list(prefix: 'phase11a/uploads/', limit: 1000)
  deleted_keys = []
  rows.each do |row|
    ct = row['content_type'].to_s
    next if ct.start_with?('image/')
    k = row['key'].to_s
    # Double-check we're still in our prefix before deleting.
    next unless k.start_with?('phase11a/uploads/')
    bucket.delete(k)
    deleted_keys << k
  end
  { 'deleted_count' => deleted_keys.length, 'deleted' => deleted_keys }.to_json
end
