# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 51 — demo /phase11a/upload
get '/phase11a/upload' do
  @title = 'Phase 11A — image upload demo'
  unless foundations_demos_enabled?
    status 404
    @content = '<p>foundations demos disabled (set HOMURABI_ENABLE_FOUNDATIONS_DEMOS=1).</p>'
    next erb :layout
  end
  @images = []
  @non_image_count = 0
  if bucket
    rows = bucket.list(prefix: 'phase11a/uploads/', limit: 50)
    # Partition into image rows (→ gallery) and non-image rows
    # (legacy curl-smoke binary payloads that predate the MIME
    # guard below). The gallery only renders real images so we
    # never draw an `<img src=…>` pointing at bytes the browser
    # can't decode.
    rows.each do |row|
      ct = row['content_type'].to_s
      if ct.start_with?('image/')
        filename = row['key'].to_s.split('/').last.to_s
        display_name = filename.sub(/\A[0-9a-f]+-/, '')
        @images << {
          'key'          => row['key'],
          'download_url' => "/phase11a/download/#{row['key']}",
          'filename'     => display_name,
          'content_type' => ct,
          'size'         => row['size'],
          'note'         => nil  # R2 doesn't preserve our custom note
        }
      else
        @non_image_count += 1
      end
    end
  end
  @content = erb :phase11a_upload
  erb :layout
end
