# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 10 — Workers AI binding wrapper.
#
# `Cloudflare::AI.run(model, inputs, binding: env['cloudflare.AI'])`
# wraps `env.AI.run(model, inputs, options)` and returns a Ruby Hash so
# Sinatra routes can call:
#
#     ai = env['cloudflare.AI']
#     out = Cloudflare::AI.run(
#             '@cf/google/gemma-4-26b-a4b-it',
#             { messages: [
#                 { role: 'system', content: 'You are a helpful assistant.' },
#                 { role: 'user',   content: 'こんにちは' }
#             ] },
#             binding: ai
#           ).__await__
#     out['response']  # => "..."
#
# Streaming (`stream: true`) returns the raw JS ReadableStream wrapped
# in `Cloudflare::AI::Stream` so a route can hand it to a Server-Sent
# Events response. See `lib/homura/runtime.rb#build_js_response`
# for the SSE / ReadableStream pass-through.

require 'json'

module Cloudflare
  class AIError < StandardError
    attr_reader :model, :operation
    def initialize(message, model: nil, operation: nil)
      @model = model
      @operation = operation
      super("[Cloudflare::AI] model=#{model || '?'} op=#{operation || 'run'}: #{message}")
    end
  end

  module AI
    # Default REST options forwarded to env.AI.run as the third argument.
    DEFAULT_OPTIONS = {}.freeze

    # Run a Workers AI model. Returns a JS Promise that resolves to a
    # Ruby Hash for non-streaming calls, or to a Cloudflare::AI::Stream
    # wrapping the JS ReadableStream for streaming calls.
    #
    # @param model [String] catalog model id, e.g. '@cf/google/gemma-4-26b-a4b-it'
    # @param inputs [Hash] model inputs (messages / prompt / max_tokens / etc.)
    # @param binding [JS object] env.AI binding (required)
    # @param options [Hash] gateway / extra options forwarded as the 3rd arg
    def self.run(model, inputs, binding: nil, options: nil)
      # Use a JS-side null check because `binding` may be a raw JS object
      # (env.AI), which has no Ruby `#nil?` method on the prototype.
      bound = !`(#{binding} == null)`
      raise AIError.new('AI binding not bound (env.AI is null)', model: model) unless bound
      js_inputs = ruby_to_js(inputs)
      js_options = options ? ruby_to_js(options) : `({})`
      ai_binding = binding
      err_klass = Cloudflare::AIError
      stream_klass = Cloudflare::AI::Stream
      # Streaming may be requested either via `inputs[:stream]` (the
       # newer Workers AI shape) or `options: { stream: true }` (the
       # 3rd-arg "options" contract). Accept both so callers can use
       # whichever idiom matches the model docs they're following.
      streaming = (inputs.is_a?(Hash) && (inputs[:stream] == true || inputs['stream'] == true)) ||
                  (options.is_a?(Hash) && (options[:stream] == true || options['stream'] == true))
      cf = Cloudflare

      # NOTE: multi-line backtick → Promise works HERE because the
      # value is assigned to `js_promise` (Opal emits the statement AND
      # keeps the returned value alive through the local). Do NOT
      # refactor this so the backtick is the method's last expression
      # or the Promise will be silently dropped (same pitfall
      # documented in lib/homura/runtime/{cache,queue}.rb —
      # Phase 11B audit).
      js_promise = `
        (async function() {
          var out;
          try {
            out = await #{ai_binding}.run(#{model}, #{js_inputs}, #{js_options});
          } catch (e) {
            #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ model: #{model}, operation: 'run' })));
          }
          return out;
        })()
      `

      js_result = js_promise.__await__

      if streaming
        # Workers AI returns a ReadableStream<Uint8Array> when stream:true.
        # Wrap it so the Sinatra route can return it as an SSE body.
        stream_klass.new(js_result)
      else
        cf.js_to_ruby(js_result)
      end
    end

    # Convert a Ruby value (Hash / Array / String / Numeric / true / false / nil)
    # into a plain JS object suitable for env.AI.run inputs.
    def self.ruby_to_js(val)
      if val.is_a?(Hash)
        obj = `({})`
        val.each do |k, v|
          ks = k.to_s
          jv = ruby_to_js(v)
          `#{obj}[#{ks}] = #{jv}`
        end
        obj
      elsif val.is_a?(Array)
        arr = `([])`
        val.each do |v|
          jv = ruby_to_js(v)
          `#{arr}.push(#{jv})`
        end
        arr
      elsif val.is_a?(Symbol)
        val.to_s
      else
        val
      end
    end

    # Streaming wrapper. Holds the raw JS ReadableStream<Uint8Array>
    # returned by env.AI.run when `stream: true` is set. Sinatra routes
    # return this from a route body and `build_js_response` recognises
    # it via duck-typing (`#sse_stream?`) to pass the stream straight
    # into `new Response(stream, …)`.
    #
    # Phase 11A: unified with Cloudflare::SSEStream so both stream
    # types go through the same `response_headers` path in
    # `build_js_response`. The AI::Stream wraps a pre-existing JS
    # ReadableStream (produced by env.AI.run), whereas SSEStream
    # produces its own. The adapter doesn't need to care — it just
    # calls `#js_stream` and `#response_headers`.
    class Stream
      attr_reader :js_stream

      def initialize(js_stream, headers: nil)
        @js_stream = js_stream
        @extra_headers = headers || {}
      end

      def sse_stream?
        true
      end

      # Merged SSE headers — same shape as SSEStream#response_headers,
      # so build_js_response can pass the stream through without a
      # special AI branch. Reference Cloudflare::SSEStream lazily so
      # this file still loads if stream.rb hasn't been required yet
      # (Phase 11A load-order flip: ai.rb currently loads first).
      def response_headers
        defaults = defined?(::Cloudflare::SSEStream) ?
          ::Cloudflare::SSEStream::DEFAULT_HEADERS :
          { 'content-type' => 'text/event-stream; charset=utf-8',
            'cache-control' => 'no-cache, no-transform',
            'x-accel-buffering' => 'no' }
        defaults.merge(@extra_headers)
      end

      def each; end
      def close; end
    end
  end

  # Generic JS->Ruby for the common Workers AI response shape:
  #   { response: "...", usage: { prompt_tokens: ... } }
  # Recursively converts nested objects + arrays.
  def self.js_to_ruby(js_val)
    return nil if `#{js_val} == null`
    return js_val if `typeof #{js_val} === 'string' || typeof #{js_val} === 'number' || typeof #{js_val} === 'boolean'`
    if `Array.isArray(#{js_val})`
      out = []
      len = `#{js_val}.length`
      i = 0
      while i < len
        out << js_to_ruby(`#{js_val}[#{i}]`)
        i += 1
      end
      return out
    end
    if `typeof #{js_val} === 'object'`
      h = {}
      keys = `Object.keys(#{js_val})`
      len = `#{keys}.length`
      i = 0
      while i < len
        k = `#{keys}[#{i}]`
        h[k] = js_to_ruby(`#{js_val}[#{k}]`)
        i += 1
      end
      return h
    end
    js_val
  end
end
