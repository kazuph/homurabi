# Phase 1 minimal Ruby app for homurabi.
#
# This file MUST stay free of any JavaScript or Cloudflare-specific
# constructs. The CF Workers runtime, the Request/Response wrappers,
# and the bridge to the JS Module Worker live in lib/cloudflare_workers.rb.
#
# Goal: prove that pure Ruby can produce the HTTP response body that
# is served from a Cloudflare Workers fetch handler.

puts "homurabi: app/hello.rb loaded"

Homurabi.handle do |request|
  puts "homurabi: handling #{request.method} #{request.path}"
  Homurabi::Response.new(
    "hello from real ruby on opal\n" \
    "method: #{request.method}\n" \
    "path:   #{request.path}\n",
    status: 200,
    headers: { 'content-type' => 'text/plain; charset=utf-8' }
  )
end
