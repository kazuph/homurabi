# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 6 — HTTP client foundation.
#
# Cloudflare::HTTP.fetch wraps globalThis.fetch (V8 / Node.js / Workers)
# and exposes a Ruby-friendly response object. Sinatra routes use
# `.__await__` inside a `# await: true` block, the same pattern that
# the D1/KV/R2 wrappers use for their JS Promises.
#
# This module is the single bridge that lets unmodified Ruby HTTP gems
# (Net::HTTP, Faraday adapters, OpenAI clients, etc.) reach the
# network. There is no socket-level fallback — everything ultimately
# goes through `globalThis.fetch`, because Cloudflare Workers does not
# expose a TCP socket API.

require 'json'

module Cloudflare
  class HTTPError < StandardError
    attr_reader :url, :method
    def initialize(message, url: nil, method: nil)
      @url = url
      @method = method
      super("[Cloudflare::HTTP] #{method || 'GET'} #{url}: #{message}")
    end
  end

  # Lightweight response wrapper around the JS Response object.
  # The body is read eagerly (text()) so callers see a plain Ruby
  # String. `headers` is a frozen Hash with lowercased string keys.
  class HTTPResponse
    attr_reader :status, :headers, :body, :url

    def initialize(status:, headers:, body:, url:)
      @status = status
      @headers = headers
      @body = body
      @url = url
    end

    def ok?
      @status >= 200 && @status < 300
    end

    def json
      JSON.parse(@body)
    end

    def [](name)
      @headers[name.to_s.downcase]
    end
  end

  module HTTP
    DEFAULT_HEADERS = {}.freeze

    # Issue an HTTP request via globalThis.fetch.
    #
    #   res = Cloudflare::HTTP.fetch('https://api.example.com/users',
    #           method: 'POST',
    #           headers: { 'content-type' => 'application/json' },
    #           body: { name: 'kazu' }.to_json).__await__
    #   res.status   # => 200
    #   res.json     # => { 'id' => 1, 'name' => 'kazu' }
    #
    # The whole response body is awaited and returned as a String.
    # Use `Cloudflare::HTTPResponse#body` to access raw text.
    def self.fetch(url, method: 'GET', headers: nil, body: nil)
      hdrs = headers || DEFAULT_HEADERS
      method_str = method.to_s.upcase
      js_headers = ruby_headers_to_js(hdrs)
      js_body = body.nil? ? nil : body.to_s
      url_str = url.to_s
      response_klass = Cloudflare::HTTPResponse
      err_klass = Cloudflare::HTTPError
      headers_to_hash = method(:js_headers_to_hash)
      _ = headers_to_hash # silence opal lint

      js_promise = `
        (async function() {
          var init = { method: #{method_str}, headers: #{js_headers}, redirect: 'follow' };
          if (#{js_body} !== nil && #{js_body} != null) { init.body = #{js_body}; }
          var resp;
          try {
            resp = await globalThis.fetch(#{url_str}, init);
          } catch (e) {
            #{Kernel}.$$raise(#{err_klass}.$new(e.message || String(e), Opal.hash({ url: #{url_str}, method: #{method_str} })));
          }
          var text = '';
          try {
            text = await resp.text();
          } catch (e) {
            text = '';
          }
          var hash_keys = [];
          var hash_vals = [];
          if (resp.headers && typeof resp.headers.forEach === 'function') {
            resp.headers.forEach(function(value, key) {
              hash_keys.push(String(key).toLowerCase());
              hash_vals.push(String(value));
            });
          }
          return { status: resp.status|0, text: text, hkeys: hash_keys, hvals: hash_vals };
        })()
      `

      js_result = js_promise.__await__
      hkeys = `#{js_result}.hkeys`
      hvals = `#{js_result}.hvals`
      h = {}
      i = 0
      len = `#{hkeys}.length`
      while i < len
        h[`#{hkeys}[#{i}]`] = `#{hvals}[#{i}]`
        i += 1
      end

      response_klass.new(
        status: `#{js_result}.status`,
        headers: h,
        body: `#{js_result}.text`,
        url: url_str
      )
    end

    # Convert a Ruby Hash<String, String> into a plain JS object usable
    # as the `headers` init for fetch().
    def self.ruby_headers_to_js(hash)
      js_obj = `{}`
      hash.each do |k, v|
        ks = k.to_s
        vs = v.to_s
        `#{js_obj}[#{ks}] = #{vs}`
      end
      js_obj
    end

    # Internal: convert JS Headers / iterable to Ruby Hash with
    # lowercased string keys. Currently inlined in fetch() but exposed
    # for completeness.
    def self.js_headers_to_hash(js_headers)
      h = {}
      `
        if (#{js_headers} && typeof #{js_headers}.forEach === 'function') {
          #{js_headers}.forEach(function(value, key) {
            #{h}.$$smap[String(key).toLowerCase()] = String(value);
          });
        }
      `
      h
    end
  end
end
