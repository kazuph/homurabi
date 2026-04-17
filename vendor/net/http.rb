# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Minimal Net::HTTP shim for Cloudflare Workers / Opal.
#
# This is NOT a port of CRuby's Net::HTTP. Cloudflare Workers does
# not expose raw TCP sockets, so the only available transport is the
# global `fetch()` API. Net::HTTP here is a thin compatibility layer
# delegating to Cloudflare::HTTP.fetch.
#
# Covered surface (the 95% of Net::HTTP usage we see in real Ruby):
#   - Net::HTTP.get(URI)            -> body String
#   - Net::HTTP.get_response(URI)   -> Net::HTTPResponse
#   - Net::HTTP.post_form(URI, hash)-> Net::HTTPResponse
#   - Net::HTTPResponse#body / #code / #[] / #message / #header
#
# Anything else (start blocks, persistent connections, basic auth via
# request objects, multipart, chunked streaming) is out of scope for
# Phase 6. Use Cloudflare::HTTP.fetch directly for those.

require 'cloudflare_workers/http'

module Net
  # Net::HTTPResponse — minimal CRuby compatibility surface.
  class HTTPResponse
    attr_reader :body, :headers

    def initialize(cloudflare_response)
      @cf = cloudflare_response
      @body = cloudflare_response.body
      @headers = cloudflare_response.headers
    end

    # CRuby's Net::HTTPResponse#code returns a String like "200".
    def code
      @cf.status.to_s
    end

    # Loose mapping; CRuby returns the HTTP status text. We synthesize
    # a label from the status code so callers that only check existence
    # do not blow up.
    def message
      case @cf.status
      when 200 then 'OK'
      when 201 then 'Created'
      when 204 then 'No Content'
      when 301 then 'Moved Permanently'
      when 302 then 'Found'
      when 400 then 'Bad Request'
      when 401 then 'Unauthorized'
      when 403 then 'Forbidden'
      when 404 then 'Not Found'
      when 500 then 'Internal Server Error'
      when 502 then 'Bad Gateway'
      when 503 then 'Service Unavailable'
      else 'HTTP ' + @cf.status.to_s
      end
    end

    # Case-insensitive header read, like CRuby Net::HTTPHeader#[].
    def [](name)
      @headers[name.to_s.downcase]
    end

    # Iterate headers (lowercased keys).
    def each_header(&block)
      @headers.each(&block)
    end
    alias_method :each, :each_header

    # CRuby uses #header for raw access; surface a Hash here.
    def header
      @headers
    end
  end

  module HTTP
    # GET the URL and return the body as a String. Mirrors
    # Net::HTTP.get(URI).
    def self.get(uri_or_url)
      url = uri_to_url(uri_or_url)
      Cloudflare::HTTP.fetch(url, method: 'GET').__await__.body
    end

    # GET and return a Net::HTTPResponse.
    def self.get_response(uri_or_url)
      url = uri_to_url(uri_or_url)
      cf_res = Cloudflare::HTTP.fetch(url, method: 'GET').__await__
      Net::HTTPResponse.new(cf_res)
    end

    # POST a Hash as application/x-www-form-urlencoded.
    def self.post_form(uri_or_url, params)
      url = uri_to_url(uri_or_url)
      body = encode_form(params)
      cf_res = Cloudflare::HTTP.fetch(
        url,
        method: 'POST',
        headers: { 'content-type' => 'application/x-www-form-urlencoded' },
        body: body
      ).__await__
      Net::HTTPResponse.new(cf_res)
    end

    # Internal: accept a URI::Generic or a String/anything respond_to?(:to_s).
    def self.uri_to_url(uri_or_url)
      return uri_or_url.to_s unless uri_or_url.respond_to?(:scheme)
      scheme = uri_or_url.scheme || 'http'
      host = uri_or_url.host || ''
      port = uri_or_url.port
      path = uri_or_url.path || '/'
      path = '/' if path.empty?
      query = uri_or_url.respond_to?(:query) ? uri_or_url.query : nil
      authority = if port && !default_port?(scheme, port)
                    host + ':' + port.to_s
                  else
                    host
                  end
      url = scheme + '://' + authority + path
      url = url + '?' + query if query && !query.empty?
      url
    end

    def self.default_port?(scheme, port)
      (scheme == 'http' && port == 80) || (scheme == 'https' && port == 443)
    end

    def self.encode_form(params)
      pairs = []
      params.each do |k, v|
        ek = url_encode(k.to_s)
        ev = url_encode(v.to_s)
        pairs << (ek + '=' + ev)
      end
      pairs.join('&')
    end

    def self.url_encode(s)
      `encodeURIComponent(#{s}).replace(/%20/g, '+')`
    end
  end
end
