# frozen_string_literal: true

App = lambda do |env|
  path = env['PATH_INFO']
  method = env['REQUEST_METHOD']

  case [method, path]
  when ['GET', '/']
    [
      200,
      { 'content-type' => 'text/plain; charset=utf-8' },
      [
        "rack-only Ruby on Cloudflare Workers\n",
        "GET /env shows Rack env proof\n"
      ]
    ]
  when ['GET', '/env']
    body = [
      "REQUEST_METHOD=#{env['REQUEST_METHOD']}",
      "PATH_INFO=#{env['PATH_INFO']}",
      "QUERY_STRING=#{env['QUERY_STRING']}",
      "HTTP_HOST=#{env['HTTP_HOST']}",
      "rack.url_scheme=#{env['rack.url_scheme']}"
    ].join("\n") + "\n"

    [200, { 'content-type' => 'text/plain; charset=utf-8' }, [body]]
  else
    [404, { 'content-type' => 'text/plain; charset=utf-8' }, ["not found\n"]]
  end
end

run App
