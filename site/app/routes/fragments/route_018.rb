# frozen_string_literal: true
# Route fragment 18 — demo /r2/:key
put("/r2/:key") do
  content_type("application/json")
  key = params["key"]
  body = begin
    request.body.read
  rescue StandardError
    ""
  end

  content_type_in = request.env["CONTENT_TYPE"] || "application/octet-stream"
  bucket.put(key, body, content_type_in)
  status(201)
  {"key" => key, "size" => body.bytesize, "stored" => true}.to_json
end
