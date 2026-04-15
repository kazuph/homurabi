# A plain Rack application.

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
