# A plain Rack application.
#
# Identical in shape to a config.ru you would feed to Puma, Unicorn,
# Falcon, WEBrick, or any other Rack-compatible server. There is nothing
# Cloudflare- or homurabi-specific here. The transport adapter that
# turns Cloudflare Workers fetch events into Rack calls lives entirely
# in lib/cloudflare_workers.rb and is invisible from this file.

app = lambda do |env|
  body = "hello from real ruby on opal\n" \
         "method: #{env['REQUEST_METHOD']}\n" \
         "path:   #{env['PATH_INFO']}\n"

  [
    200,
    { 'content-type' => 'text/plain; charset=utf-8' },
    [body]
  ]
end

run app
