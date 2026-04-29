# frozen_string_literal: true
# Route fragment 53 — demo /phase11a/uploads/*
delete '/phase11a/uploads/*' do
  content_type 'application/json'
  unless foundations_demos_enabled?
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURA_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  if bucket.nil?
    status 503
    next({ 'error' => 'R2 binding not configured' }.to_json)
  end
  key = params['splat'].is_a?(Array) ? params['splat'].join('/') : params['splat'].to_s
  full = "phase11a/uploads/#{key}"
  # Safety: only ever delete under our own prefix. The splat route
  # already enforces this prefix structurally, but a belt-and-braces
  # startswith check protects against future routing changes.
  unless full.start_with?('phase11a/uploads/')
    status 400
    next({ 'error' => 'refusing to delete outside phase11a/uploads/', 'key' => full }.to_json)
  end
  bucket.delete(full)
  { 'deleted' => true, 'key' => full }.to_json
end
