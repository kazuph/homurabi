# frozen_string_literal: true
# Route fragment 50 — api /api/upload
post '/api/upload' do
  content_type 'application/json'
  unless foundations_demos_enabled?
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  # pull params BEFORE the first await — Sinatra clears @params when
  # it starts a Promise-returning route (same ceremony as /d1/users).
  file_param = params['file']
  note_param = params['note'].to_s
  unless file_param.is_a?(::Cloudflare::UploadedFile)
    status 400
    next({ 'error' => 'missing "file" multipart part' }.to_json)
  end

  # Only accept images — this is the /phase11a/upload demo's purpose.
  # Rejecting non-image content types here stops the gallery ever
  # accumulating bytes it can't render (the historical curl-smoke
  # `.bin` payloads came in before this check existed).
  ct = file_param.content_type.to_s
  unless ct.start_with?('image/')
    status 415  # Unsupported Media Type
    next({
      'error'         => 'only image/* content types are accepted',
      'received_type' => ct.empty? ? '(missing)' : ct,
      'filename'      => file_param.filename
    }.to_json)
  end

  if bucket.nil?
    status 503
    next({ 'error' => 'R2 binding not configured' }.to_json)
  end

  # Pick a random key under a phase11a/ prefix so we don't collide
  # with the existing /r2/:key demos.
  key = "phase11a/uploads/#{SecureRandom.hex(8)}-#{file_param.filename}"
  u8  = file_param.to_uint8_array
  bucket.put(key, u8, file_param.content_type)

  status 201
  {
    'stored'       => true,
    'key'          => key,
    'filename'     => file_param.filename,
    'content_type' => file_param.content_type,
    'size'         => file_param.size,
    'note'         => note_param,
    'url'          => "/r2/#{key}"  # hit via GET /images/:key for binary
  }.to_json
end
