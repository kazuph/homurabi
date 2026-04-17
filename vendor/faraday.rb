# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 11A — Faraday compatibility layer.
#
# This is NOT a port of the real ruby-faraday gem (which carries ~9 kLOC
# of middleware plumbing, net-http/excon/typhoeus adapters, UnixSocket
# handling, etc.). Cloudflare Workers has a single transport: the global
# `fetch()` API. We therefore re-implement the ~5% of Faraday's surface
# that a typical Ruby gem (octokit, slack-ruby-client, openai-ruby, ...)
# actually uses, backed by `Cloudflare::HTTP.fetch`.
#
# Covered surface (ordered by how much it matters for downstream gems):
#
#   - Faraday.get / post / put / delete / patch / head  (top-level shortcuts)
#   - Faraday.new(url:, headers:, params:) { |c| ... }  (Connection builder)
#   - Connection#get / post / put / delete / patch / head
#   - Connection#request :json / :url_encoded / :authorization
#   - Connection#response :json / :raise_error / :logger
#   - Request builder block:
#       conn.post('/foo') do |req|
#         req.headers['X-Custom'] = 'y'
#         req.body = { a: 1 }
#         req.params['flag'] = 1
#       end
#   - Response#status / body / headers / success? / reason_phrase / env
#   - Error classes:
#       Faraday::Error (base)
#         ├─ Faraday::ClientError   (4xx)
#         │    ├─ Faraday::BadRequestError        (400)
#         │    ├─ Faraday::UnauthorizedError      (401)
#         │    ├─ Faraday::ForbiddenError         (403)
#         │    ├─ Faraday::ResourceNotFound       (404)
#         │    ├─ Faraday::ConflictError          (409)
#         │    └─ Faraday::UnprocessableEntityError (422)
#         ├─ Faraday::ServerError   (5xx)
#         ├─ Faraday::TimeoutError
#         └─ Faraday::ConnectionFailed
#   - Faraday::Utils.build_query(hash)  (nested bracket encoding)
#
# Not covered (deliberately):
#   - Adapters (net_http / excon / typhoeus). Workers has only fetch().
#   - Multipart request body builder (Faraday::Multipart). Post a String.
#   - Custom middleware registration. Use the built-ins above.

require 'json'
require 'cloudflare_workers/http'

module Faraday
  VERSION = '2.0.0-homurabi-shim'

  # --------------------------------------------------------------------
  # Error classes
  # --------------------------------------------------------------------

  class Error < StandardError
    attr_reader :response

    def initialize(message, response = nil)
      @response = response
      super(message)
    end

    # Mirrors the real Faraday::Error#response_status helper.
    def response_status
      @response && @response[:status]
    end

    def response_body
      @response && @response[:body]
    end

    def response_headers
      @response && @response[:headers]
    end
  end

  class ClientError < Error; end
  class ServerError < Error; end
  class TimeoutError < Error; end
  class ConnectionFailed < Error; end
  class SSLError < Error; end
  class ParsingError < Error; end
  class RetriableResponse < Error; end

  class BadRequestError < ClientError; end
  class UnauthorizedError < ClientError; end
  class ForbiddenError < ClientError; end
  class ResourceNotFound < ClientError; end
  class ProxyAuthError < ClientError; end
  class ConflictError < ClientError; end
  class UnprocessableEntityError < ClientError; end
  class TooManyRequestsError < ClientError; end

  # --------------------------------------------------------------------
  # Utils — URL / query helpers
  # --------------------------------------------------------------------

  module Utils
    module_function

    # Percent-encode a single component. encodeURIComponent covers the
    # vast majority of real-world cases; Faraday itself delegates to
    # URI::DEFAULT_PARSER#escape which is equivalent for ASCII + common
    # unreserved bytes.
    def escape(s)
      `encodeURIComponent(#{s.to_s})`
    end

    def unescape(s)
      `decodeURIComponent(#{s.to_s})`
    end

    # Build a URL-encoded query string from a Hash. Supports nested
    # arrays / hashes the same way Faraday::Utils::NestedParamsEncoder
    # does (`a[]=1&a[]=2`, `a[b]=1`).
    def build_query(params)
      return '' if params.nil? || params.empty?
      pairs = []
      params.each do |k, v|
        encode_pair(pairs, k.to_s, v)
      end
      pairs.join('&')
    end

    def encode_pair(pairs, key, value)
      if value.is_a?(Hash)
        value.each { |sk, sv| encode_pair(pairs, "#{key}[#{sk}]", sv) }
      elsif value.is_a?(Array)
        value.each { |sv| encode_pair(pairs, "#{key}[]", sv) }
      elsif value.nil?
        pairs << (escape(key) + '=')
      else
        pairs << (escape(key) + '=' + escape(value.to_s))
      end
    end

    # Merge two query-param Hashes, second argument wins on conflict.
    def merge_params(a, b)
      out = {}
      a&.each { |k, v| out[k.to_s] = v }
      b&.each { |k, v| out[k.to_s] = v }
      out
    end

    # Append a query string to a URL, respecting any existing `?`.
    def append_query(url, query)
      return url if query.nil? || query.empty?
      sep = url.include?('?') ? '&' : '?'
      url + sep + query
    end
  end

  # --------------------------------------------------------------------
  # Env — the object passed through the middleware chain
  # --------------------------------------------------------------------

  class Env
    attr_accessor :method, :url, :body, :request_headers,
                  :params, :status, :response_headers, :reason_phrase

    def initialize(method:, url:, body: nil, headers: {}, params: {})
      @method = method.to_s.downcase.to_sym
      @url = url
      @body = body
      @request_headers = headers.dup
      @params = params.dup
      @status = nil
      @response_headers = {}
      @reason_phrase = ''
    end

    # Convenience — the request URL with the params merged into the
    # query string.
    def full_url
      Utils.append_query(@url.to_s, Utils.build_query(@params))
    end

    def success?
      !@status.nil? && @status >= 200 && @status < 300
    end

    # Minimal Hash-like view for error objects (Faraday::Error#response).
    def to_response_hash
      {
        status: @status,
        body: @body,
        headers: @response_headers,
        url: full_url,
        reason_phrase: @reason_phrase
      }
    end
  end

  # --------------------------------------------------------------------
  # Response
  # --------------------------------------------------------------------

  class Response
    attr_reader :env

    def initialize(env)
      @env = env
    end

    def status;          @env.status;            end
    def body;            @env.body;              end
    def headers;         @env.response_headers;  end
    def reason_phrase;   @env.reason_phrase;     end
    def success?;        @env.success?;          end
    def finished?;       true;                   end

    # [] on a response fetches a response header (case-insensitive).
    def [](name)
      @env.response_headers[name.to_s.downcase]
    end

    def to_hash
      @env.to_response_hash
    end
  end

  # --------------------------------------------------------------------
  # Middleware
  # --------------------------------------------------------------------
  #
  # Each middleware responds to #on_request(env) and/or #on_response(env).
  # The connection calls on_request in registration order before the
  # HTTP roundtrip, and on_response in reverse-registration order after.

  module Middleware
    class Base
      def on_request(env); end
      def on_response(env); end
    end

    # Encode request body as JSON (when it's a Hash or Array) and set
    # Content-Type: application/json. Parse response body as JSON when
    # response Content-Type looks JSON-ish.
    class JSON < Base
      def initialize(parser_options: nil)
        @parser_options = parser_options || {}
      end

      def on_request(env)
        b = env.body
        return if b.nil?
        return if b.is_a?(String)
        return unless b.is_a?(Hash) || b.is_a?(Array)
        env.body = b.to_json
        env.request_headers['content-type'] ||= 'application/json'
      end

      def on_response(env)
        ct = (env.response_headers['content-type'] || '').to_s
        return unless json_ct?(ct)
        raw = env.body.to_s
        return if raw.empty?
        begin
          env.body = ::JSON.parse(raw)
        rescue ::JSON::ParserError => e
          raise Faraday::ParsingError.new(e.message, env.to_response_hash)
        end
      end

      def json_ct?(ct)
        ct.downcase.include?('json')
      end
    end

    # Encode Hash bodies as application/x-www-form-urlencoded. Faraday
    # default for POSTed Hashes without `:json` middleware.
    class UrlEncoded < Base
      def on_request(env)
        b = env.body
        return if b.nil?
        return if b.is_a?(String)
        return unless b.is_a?(Hash)
        env.body = Faraday::Utils.build_query(b)
        env.request_headers['content-type'] ||= 'application/x-www-form-urlencoded'
      end
    end

    # Raise a typed error for 4xx / 5xx responses — mirrors the real
    # Faraday `response :raise_error` middleware.
    class RaiseError < Base
      def on_response(env)
        code = env.status.to_i
        return if code < 400 || code >= 600
        resp = env.to_response_hash
        msg = "the server responded with status #{code}"
        case code
        when 400 then raise Faraday::BadRequestError.new(msg, resp)
        when 401 then raise Faraday::UnauthorizedError.new(msg, resp)
        when 403 then raise Faraday::ForbiddenError.new(msg, resp)
        when 404 then raise Faraday::ResourceNotFound.new(msg, resp)
        when 407 then raise Faraday::ProxyAuthError.new(msg, resp)
        when 409 then raise Faraday::ConflictError.new(msg, resp)
        when 422 then raise Faraday::UnprocessableEntityError.new(msg, resp)
        when 429 then raise Faraday::TooManyRequestsError.new(msg, resp)
        when 400..499 then raise Faraday::ClientError.new(msg, resp)
        when 500..599 then raise Faraday::ServerError.new(msg, resp)
        end
      end
    end

    # Set the Authorization header. Faraday::Request::Authorization
    # supports `:basic`, `:bearer`, or a literal string value.
    class Authorization < Base
      def initialize(type_or_value, token = nil)
        @type = type_or_value.is_a?(Symbol) ? type_or_value : nil
        @token = token
        @raw = @type.nil? ? type_or_value.to_s : nil
      end

      def on_request(env)
        env.request_headers['authorization'] = build_value
      end

      def build_value
        return @raw if @raw
        case @type
        when :basic   then 'Basic ' + base64("#{@token}")
        when :bearer  then "Bearer #{@token}"
        when :token   then "Token #{@token}"
        else               @token.to_s
        end
      end

      def base64(s)
        `globalThis.btoa(#{s})`
      end
    end

    # Minimal logger middleware. Writes METHOD URL STATUS via Ruby's
    # $stdout (which routes to console.log on Workers).
    class Logger < Base
      def initialize(io = nil, tag: 'Faraday')
        @io = io || $stdout
        @tag = tag
      end

      def on_request(env)
        @io.puts "[#{@tag}] -> #{env.method.to_s.upcase} #{env.full_url}"
      end

      def on_response(env)
        @io.puts "[#{@tag}] <- #{env.status} (#{env.reason_phrase})"
      end
    end
  end

  # Registry so `c.request :json` / `c.response :raise_error` resolve.
  MIDDLEWARE_REGISTRY = {
    request: {
      json:           Middleware::JSON,
      url_encoded:    Middleware::UrlEncoded,
      authorization:  Middleware::Authorization
    },
    response: {
      json:        Middleware::JSON,
      raise_error: Middleware::RaiseError,
      logger:      Middleware::Logger
    }
  }.freeze

  # --------------------------------------------------------------------
  # Request (passed to block in `conn.post('/foo') { |req| ... }`)
  # --------------------------------------------------------------------

  class Request
    attr_accessor :method, :path, :body, :headers, :params

    def initialize(method, path)
      @method = method
      @path = path
      @body = nil
      @headers = {}
      @params = {}
    end
  end

  # --------------------------------------------------------------------
  # Connection
  # --------------------------------------------------------------------

  class Connection
    attr_reader :url_prefix, :headers, :params, :request_middlewares, :response_middlewares

    def initialize(url: nil, headers: nil, params: nil)
      @url_prefix = url.to_s
      @headers = normalize_headers(headers || {})
      @params = (params || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      @request_middlewares = []
      @response_middlewares = []
      yield self if block_given?
    end

    # Register a request-phase middleware. The real Faraday also accepts
    # anonymous classes; we accept a symbol keyed in MIDDLEWARE_REGISTRY.
    def request(name, *args, **opts)
      klass = MIDDLEWARE_REGISTRY[:request][name]
      raise ArgumentError, "unknown request middleware: #{name.inspect}" unless klass
      mw = opts.any? ? klass.new(*args, **opts) : klass.new(*args)
      @request_middlewares << mw
      mw
    end

    def response(name, *args, **opts)
      klass = MIDDLEWARE_REGISTRY[:response][name]
      raise ArgumentError, "unknown response middleware: #{name.inspect}" unless klass
      mw = opts.any? ? klass.new(*args, **opts) : klass.new(*args)
      @response_middlewares << mw
      mw
    end

    # --- HTTP verb shortcuts ------------------------------------------

    def get(path = nil, params = nil, headers = nil)
      run_request(:get, path, nil, headers, params)
    end

    def head(path = nil, params = nil, headers = nil)
      run_request(:head, path, nil, headers, params)
    end

    def delete(path = nil, params = nil, headers = nil)
      run_request(:delete, path, nil, headers, params)
    end

    def post(path = nil, body = nil, headers = nil, &block)
      run_request(:post, path, body, headers, nil, &block)
    end

    def put(path = nil, body = nil, headers = nil, &block)
      run_request(:put, path, body, headers, nil, &block)
    end

    def patch(path = nil, body = nil, headers = nil, &block)
      run_request(:patch, path, body, headers, nil, &block)
    end

    # Main entry point. When a block is given the block is invoked with
    # a mutable Request (`conn.post('/foo') { |req| req.body = ...}`).
    def run_request(method, path, body, headers, params, &block)
      req = Request.new(method, path)
      req.body = body if body
      req.headers = normalize_headers(headers) if headers
      req.params = params ? stringify_keys(params) : {}
      block&.call(req)

      full_url = build_full_url(req.path, req.params)
      merged_headers = merge_headers(@headers, req.headers)

      env = Env.new(
        method: method,
        url: full_url,
        body: req.body,
        headers: merged_headers,
        params: req.params
      )

      @request_middlewares.each { |mw| mw.on_request(env) }

      cf_res = Cloudflare::HTTP.fetch(
        env.url,
        method: env.method.to_s.upcase,
        headers: env.request_headers,
        body: env.body
      ).__await__

      env.status = cf_res.status
      env.response_headers = cf_res.headers
      env.body = cf_res.body
      env.reason_phrase = http_reason(cf_res.status)

      @response_middlewares.reverse_each { |mw| mw.on_response(env) }

      Response.new(env)
    end

    # --- helpers -------------------------------------------------------

    def normalize_headers(h)
      out = {}
      h.each { |k, v| out[k.to_s.downcase] = v.to_s }
      out
    end

    def stringify_keys(h)
      out = {}
      h.each { |k, v| out[k.to_s] = v }
      out
    end

    def merge_headers(base, extra)
      out = {}
      base.each { |k, v| out[k.to_s.downcase] = v.to_s }
      extra.each { |k, v| out[k.to_s.downcase] = v.to_s }
      out
    end

    def build_full_url(path, req_params)
      if path.nil? || path.empty?
        base = @url_prefix
      elsif path.start_with?('http://') || path.start_with?('https://')
        base = path
      elsif @url_prefix.empty?
        base = path
      else
        sep = @url_prefix.end_with?('/') || path.start_with?('/') ? '' : '/'
        base = @url_prefix + sep + path
      end

      all_params = Utils.merge_params(@params, req_params)
      Utils.append_query(base, Utils.build_query(all_params))
    end

    def http_reason(code)
      case code.to_i
      when 200 then 'OK'
      when 201 then 'Created'
      when 204 then 'No Content'
      when 301 then 'Moved Permanently'
      when 302 then 'Found'
      when 304 then 'Not Modified'
      when 400 then 'Bad Request'
      when 401 then 'Unauthorized'
      when 403 then 'Forbidden'
      when 404 then 'Not Found'
      when 409 then 'Conflict'
      when 422 then 'Unprocessable Entity'
      when 429 then 'Too Many Requests'
      when 500 then 'Internal Server Error'
      when 502 then 'Bad Gateway'
      when 503 then 'Service Unavailable'
      else          'HTTP ' + code.to_s
      end
    end
  end

  # --------------------------------------------------------------------
  # Top-level convenience API
  # --------------------------------------------------------------------

  class << self
    # Faraday.new(url: 'https://...') { |c| ... } → Connection.
    def new(url: nil, headers: nil, params: nil, &block)
      Connection.new(url: url, headers: headers, params: params, &block)
    end

    # Faraday.default_connection — a Connection with `:json` on both
    # sides so `Faraday.get('https://api.github.com/users/kazuph').body`
    # yields a parsed Hash.
    def default_connection
      @default_connection ||= Connection.new do |c|
        c.request :json
        c.response :json
      end
    end

    def reset_default_connection
      @default_connection = nil
    end

    def get(url, params = nil, headers = nil)
      default_connection.get(url, params, headers)
    end

    def head(url, params = nil, headers = nil)
      default_connection.head(url, params, headers)
    end

    def delete(url, params = nil, headers = nil)
      default_connection.delete(url, params, headers)
    end

    def post(url, body = nil, headers = nil, &block)
      default_connection.post(url, body, headers, &block)
    end

    def put(url, body = nil, headers = nil, &block)
      default_connection.put(url, body, headers, &block)
    end

    def patch(url, body = nil, headers = nil, &block)
      default_connection.patch(url, body, headers, &block)
    end
  end
end
