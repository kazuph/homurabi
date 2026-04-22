# frozen_string_literal: true
# Route fragment 55 — demo /demo/stream
get '/demo/stream' do
  unless foundations_demos_enabled?
    content_type 'application/json'
    status 404
    next({ 'error' => 'foundations demos disabled (set HOMURA_ENABLE_FOUNDATIONS_DEMOS=1)' }.to_json)
  end
  stream do |out|
    i = 0
    while i < 3
      out << "chunk #{i} @ #{Time.now.to_i}\n"
      out.sleep(0.5)
      i += 1
    end
    out << "done\n"
  end
end
