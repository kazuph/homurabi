# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 10 — Workers AI binding wrapper.
#
# `ai.run(model, inputs)` wraps `env.AI.run(model, inputs, options)` and
# returns a Ruby Hash so Sinatra routes can call:
#
#     out = ai.run(
#             '@cf/google/gemma-4-26b-a4b-it',
#             messages: [
#                 { role: 'system', content: 'You are a helpful assistant.' },
#                 { role: 'user',   content: 'こんにちは' }
#             ]
#           ).__await__
#     out['response']  # => "..."
#
# Streaming (`stream: true`) returns the raw JS ReadableStream wrapped
# in `Cloudflare::AI::Stream` so a route can hand it to a Server-Sent
# Events response. See `lib/homura/runtime.rb#build_js_response`
# for the SSE / ReadableStream pass-through.

require "json"

module Cloudflare
  class AIError < StandardError
    attr_reader :model, :operation
    def initialize(message, model: nil, operation: nil)
      @model = model
      @operation = operation
      super(
        "[Cloudflare::AI] model=#{model || "?"} op=#{operation || "run"}: #{message}"
      )
    end
  end

  module AI
    # Default REST options forwarded to env.AI.run as the third argument.
    DEFAULT_OPTIONS = {}.freeze
    DEFAULT_CHAT_MODEL = "@cf/moonshotai/kimi-k2.6"
    DEFAULT_TRANSCRIBE_MODEL = "@cf/openai/whisper"
    DEFAULT_SPEAK_MODEL = "@cf/deepgram/aura-1"

    class Binding
      attr_reader :js

      def initialize(js)
        @js = js
      end

      def available?
        js = @js
        !!`(#{js} !== null && #{js} !== undefined && #{js} !== Opal.nil)`
      end

      def run(model, inputs = nil, options: nil, **input_options)
        payload = inputs || input_options
        if inputs.is_a?(Hash) &&
            !input_options.empty?
          payload = payload.merge(input_options)
        end

        Cloudflare::AI.run(model, payload, binding: @js, options: options)
      end

      def run_stream(model, inputs = nil, **input_options)
        payload = inputs || input_options
        if inputs.is_a?(Hash) &&
            !input_options.empty?
          payload = payload.merge(input_options)
        end

        run(model, payload.merge(stream: true))
      end

      def chat(
        prompt = nil,
        messages: nil,
        system: nil,
        model: DEFAULT_CHAT_MODEL,
        options: nil,
        **input_options
      )
        chat_options = Cloudflare::AI.chat_input_options(model, input_options)
        payload = {
          messages: Cloudflare::AI.build_messages(
            prompt,
            messages: messages,
            system: system
          )
        }.merge(chat_options)
        run(model, payload, options: options)
      end

      def chat_text(
        prompt = nil,
        messages: nil,
        system: nil,
        model: DEFAULT_CHAT_MODEL,
        options: nil,
        **input_options
      )
        response = chat(
          prompt,
          messages: messages,
          system: system,
          model: model,
          options: options,
          **input_options
        )
        response = response.__await__ if Cloudflare.js_promise?(response)
        Cloudflare::AI.extract_text(response)
      end

      def transcribe(
        audio,
        model: DEFAULT_TRANSCRIBE_MODEL,
        options: nil,
        **input_options
      )
        payload = {audio: Cloudflare::AI.audio_input(audio)}.merge(
          input_options
        )
        run(model, payload, options: options)
      end

      def transcribe_text(
        audio,
        model: DEFAULT_TRANSCRIBE_MODEL,
        options: nil,
        **input_options
      )
        response = transcribe(audio, model: model, options: options, **input_options)
        response = response.__await__ if Cloudflare.js_promise?(response)
        Cloudflare::AI.extract_text(response)
      end

      def speak(text, model: DEFAULT_SPEAK_MODEL, options: nil, **input_options)
        payload = {text: text.to_s}.merge(input_options)
        response = Cloudflare::AI.speak(model, payload, binding: @js, options: options)
        response = response.__await__ if Cloudflare.js_promise?(response)
        response
      end

      def speak_data_url(
        text,
        model: DEFAULT_SPEAK_MODEL,
        options: nil,
        **input_options
      )
        payload = {text: text.to_s}.merge(input_options)
        response = Cloudflare::AI.speak_data_url(
          model,
          payload,
          binding: @js,
          options: options
        )
        response = response.__await__ if Cloudflare.js_promise?(response)
        response.to_s
      end
    end

    # Run a Workers AI model. Returns a JS Promise that resolves to a
    # Ruby Hash for non-streaming calls, or to a Cloudflare::AI::Stream
    # wrapping the JS ReadableStream for streaming calls.
    #
    # @param model [String] catalog model id, e.g. '@cf/google/gemma-4-26b-a4b-it'
    # @param inputs [Hash] model inputs (messages / prompt / max_tokens / etc.)
    # @param binding [JS object] env.AI binding (required)
    # @param options [Hash] gateway / extra options forwarded as the 3rd arg
    def self.run(model, inputs, binding: nil, options: nil, raw_response: false)
      if defined?(Binding) &&
          `(#{binding} != null && #{binding}.$$class === #{Binding})`
        binding = binding.js
      end
      # Use a JS-side null check because `binding` may be a raw JS object
      # (env.AI), which has no Ruby `#nil?` method on the prototype.
      bound = !`(#{binding} == null)`
      unless bound
        raise AIError.new("AI binding not bound (env.AI is null)", model: model)
      end

      js_inputs = ruby_to_js(inputs)
      js_options = options ? ruby_to_js(options) : `({})`
      ai_binding = binding
      err_klass = Cloudflare::AIError
      stream_klass = Cloudflare::AI::Stream
      # Streaming may be requested either via `inputs[:stream]` (the
      # newer Workers AI shape) or `options: { stream: true }` (the
      # 3rd-arg "options" contract). Accept both so callers can use
      # whichever idiom matches the model docs they're following.
      streaming = (inputs.is_a?(Hash) &&
        (inputs[:stream] == true || inputs["stream"] == true)) ||
        (options.is_a?(Hash) &&
          (options[:stream] == true || options["stream"] == true))
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

      if raw_response
        RawResponse.new(js_result)
      elsif streaming
        # Workers AI returns a ReadableStream<Uint8Array> when stream:true.
        # Wrap it so the Sinatra route can return it as an SSE body.
        stream_klass.new(js_result)
      else
        cf.js_to_ruby(js_result)
      end
    end

    def self.speak(model, inputs, binding: nil, options: nil)
      if defined?(Binding) &&
          `(#{binding} != null && #{binding}.$$class === #{Binding})`
        binding = binding.js
      end

      bound = !`(#{binding} == null)`
      unless bound
        raise AIError.new("AI binding not bound (env.AI is null)", model: model)
      end

      js_inputs = ruby_to_js(inputs)
      js_options = ruby_to_js((options || {}).merge(returnRawResponse: true))
      ai_binding = binding
      err_klass = Cloudflare::AIError

      js_response = `
        (async function() {
          try {
            return await #{ai_binding}.run(#{model}, #{js_inputs}, #{js_options});
          } catch (e) {
            #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ model: #{model}, operation: 'speak' })));
          }
        })()
      `
        .__await__

      content_type = `#{js_response}.headers.get("content-type") || "application/octet-stream"`
      cache_control = `#{js_response}.headers.get("cache-control")`
      BinaryBody.new(`#{js_response}.body`, content_type, cache_control)
    end

    def self.speak_data_url(model, inputs, binding: nil, options: nil)
      if defined?(Binding) &&
          `(#{binding} != null && #{binding}.$$class === #{Binding})`
        binding = binding.js
      end

      bound = !`(#{binding} == null)`
      unless bound
        raise AIError.new("AI binding not bound (env.AI is null)", model: model)
      end

      js_inputs = ruby_to_js(inputs)
      js_options = ruby_to_js((options || {}).merge(returnRawResponse: true))
      ai_binding = binding
      err_klass = Cloudflare::AIError

      js_response = `
        (async function() {
          try {
            return await #{ai_binding}.run(#{model}, #{js_inputs}, #{js_options});
          } catch (e) {
            #{Kernel}.$raise(#{err_klass}.$new(e && e.message ? e.message : String(e), Opal.hash({ model: #{model}, operation: 'speak_data_url' })));
          }
        })()
      `
        .__await__

      content_type = `#{js_response}.headers.get("content-type") || "application/octet-stream"`
      `
        (async function(resp, ct) {
          var buf = await resp.arrayBuffer();
          var bytes = new Uint8Array(buf);
          var bin = '';
          for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
          return 'data:' + ct + ';base64,' + globalThis.btoa(bin);
        })(#{js_response}, #{content_type})
      `
        .__await__
    end

    def self.build_messages(prompt = nil, messages: nil, system: nil)
      out = []
      out << {role: "system", content: system.to_s} if system
      if messages
        unless messages.is_a?(Array)
          raise ArgumentError, "messages must be an Array of chat messages"
        end

        out.concat(messages)
      end

      out << {role: "user", content: prompt.to_s} unless prompt.nil?
      raise ArgumentError, "chat requires a prompt or messages" if out.empty?
      out
    end

    def self.audio_input(audio)
      if audio.respond_to?(:to_uint8_array)
        uint8 = audio.to_uint8_array
        return `Array.from(#{uint8})`
      end

      return audio if audio.is_a?(Array)
      if `typeof #{audio} !== 'undefined' && #{audio} instanceof Uint8Array`
        return `Array.from(#{audio})`
      end

      audio
    end

    def self.chat_input_options(model, input_options)
      return input_options unless model.to_s == DEFAULT_CHAT_MODEL

      options = input_options.dup
      key = if options.key?(:chat_template_kwargs)
        :chat_template_kwargs
      elsif options.key?("chat_template_kwargs")
        "chat_template_kwargs"
      end

      template_kwargs = key ? options[key] : nil
      if template_kwargs && !template_kwargs.is_a?(Hash)
        raise ArgumentError, "chat_template_kwargs must be a Hash"
      end

      merged = (template_kwargs || {}).dup
      unless merged.key?(:thinking) || merged.key?("thinking")
        merged[:thinking] = false
      end

      options[key || :chat_template_kwargs] = merged
      options
    end

    def self.extract_text(out)
      return out.to_s unless out.is_a?(Hash)
      if out["choices"].is_a?(Array) && !out["choices"].empty?
        msg = out["choices"][0].is_a?(Hash) ? out["choices"][0]["message"] : nil
        text = message_hash_text(msg)
        return text unless text.empty?
      end

      if out["messages"].is_a?(Array) && !out["messages"].empty?
        msg = out["messages"].find do |entry|
          entry.is_a?(Hash) && entry["role"].to_s == "assistant"
        end ||
          out["messages"][0]
        text = message_hash_text(msg)
        return text unless text.empty?
      end

      %w[text transcription response result output].each do |key|
        value = message_content_text(out[key])
        return value unless value.empty?
      end

      nested = out["result"]
      return extract_text(nested) if nested.is_a?(Hash)
      ""
    end

    def self.message_content_text(value)
      case value
      when String
        value
      when Array
        value
          .map { |part| part.is_a?(Hash) ? part["text"].to_s : part.to_s }
          .join
      else
        ""
      end
    end

    def self.message_hash_text(value)
      return "" unless value.is_a?(Hash)
      %w[
        content
        reasoning
        reasoning_content
        reasoningContent
        text
      ].each do |key|
        text = message_content_text(value[key])
        return text unless text.empty?
      end

      ""
    end

    # Convert a Ruby value (Hash / Array / String / Numeric / true / false / nil)
    # into a plain JS object suitable for env.AI.run inputs.
    def self.ruby_to_js(val)
      if `#{val} != null && typeof #{val} === 'object' && #{val}.$$class == null`
        return val
      end

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
        defaults = (
          if defined?(::Cloudflare::SSEStream)
            ::Cloudflare::SSEStream::DEFAULT_HEADERS
          else
            {
              "content-type" => "text/event-stream; charset=utf-8",
              "cache-control" => "no-cache, no-transform",
              "x-accel-buffering" => "no"
            }
          end
        )
        defaults.merge(@extra_headers)
      end

      def each
      end

      def close
      end
    end
  end

  # Generic JS->Ruby for the common Workers AI response shape:
  #   { response: "...", usage: { prompt_tokens: ... } }
  # Recursively converts nested objects + arrays.
  def self.js_to_ruby(js_val)
    return nil if `#{js_val} == null`
    if `typeof #{js_val} === 'string' || typeof #{js_val} === 'number' || typeof #{js_val} === 'boolean'`
      return js_val
    end

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
