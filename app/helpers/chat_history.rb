# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true

module Homurabi
  # D1/KV/R2 + Cache / Queue gates, plus Workers AI chat history helpers.
  module CloudflareBindingHelpers
    def db;     env['cloudflare.DB'];     end
    def kv;     env['cloudflare.KV'];     end
    def bucket; env['cloudflare.BUCKET']; end

    def crypto_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_CRYPTO_DEMOS) || ''`
      val.to_s == '1'
    end

    def scheduled_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_SCHEDULED_DEMOS) || ''`
      val.to_s == '1'
    end

    def binding_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_BINDING_DEMOS) || ''`
      val.to_s == '1'
    end

    def do_counter
      env['cloudflare.DO_COUNTER']
    end

    def cache
      @cache ||= ::Cloudflare::Cache.default
    end

    def jobs_queue
      env['cloudflare.QUEUE_JOBS']
    end

    def jobs_dlq
      env['cloudflare.QUEUE_JOBS_DLQ']
    end

    def send_email
      env['cloudflare.SEND_EMAIL']
    end

    # Phase 17 — verified sender after Cloudflare Email Service domain onboarding (`wrangler.toml` [vars]).
    def homurabi_mail_from
      cf_env = env['cloudflare.env']
      return '' unless cf_env
      `(#{cf_env}.HOMURABI_MAIL_FROM || '')`.to_s.strip
    end

    def cache_get(cache_key, ttl: 60, content_type_override: nil, &block)
      raise ArgumentError, 'cache_get requires a block' unless block
      cache_ttl = ttl.to_i
      if cache_ttl <= 0
        raise ArgumentError, "cache_get ttl must be > 0 (got #{ttl.inspect}); Workers refuses to store max-age=0"
      end
      c = cache
      cached = c.match(cache_key).__await__
      if cached
        cached.headers.each { |k, v| response.headers[k] = v }
        response.headers['x-homurabi-cache'] = 'HIT'
        return cached.body
      end
      body = block.call
      ct = content_type_override || response['Content-Type'] || 'text/plain; charset=utf-8'
      c.put(
        cache_key, body,
        status: 200,
        headers: {
          'content-type'     => ct,
          'cache-control'    => "public, max-age=#{cache_ttl}",
          'date'             => Time.now.httpdate,
          'x-homurabi-cache' => 'MISS'
        }
      ).__await__
      response.headers['x-homurabi-cache'] = 'MISS'
      body
    end
  end

  module ChatHistoryHelpers
    SESSION_ID_RE = /\A[A-Za-z0-9_-]{1,64}\z/.freeze

    def ai_demos_enabled?
      cf_env = env['cloudflare.env']
      return false unless cf_env
      val = `(#{cf_env} && #{cf_env}.HOMURABI_ENABLE_AI_DEMOS) || ''`
      val.to_s == '1'
    end

    def ai_binding
      env['cloudflare.AI']
    end

    def ai_binding?
      v = env['cloudflare.AI']
      `(#{v} != null)`
    end

    def parse_json_body
      raw = request.body.read.to_s
      return {} if raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError, StandardError
      {}
    end

    def normalize_session_id(raw)
      s = raw.to_s
      return 'demo' if s.empty?
      SESSION_ID_RE.match?(s) ? s : 'demo'
    end

    def chat_kv_key(session_id)
      "chat:#{session_id}"
    end

    def load_chat_history(session_id)
      return [] unless kv
      raw = kv.get(chat_kv_key(session_id)).__await__
      return [] if raw.nil? || raw.empty?
      arr = JSON.parse(raw)
      arr.is_a?(Array) ? arr : []
    rescue JSON::ParserError
      []
    end

    def save_chat_history(session_id, history)
      return unless kv
      trimmed = history.last(App::CHAT_HISTORY_LIMIT)
      kv.put(chat_kv_key(session_id), trimmed.to_json, expiration_ttl: App::CHAT_HISTORY_TTL).__await__
    end

    def clear_chat_history(session_id)
      return unless kv
      kv.delete(chat_kv_key(session_id)).__await__
    end

    def build_ai_messages(history, latest_user_text)
      msgs = [{ 'role' => 'system', 'content' => App::CHAT_SYSTEM_PROMPT }]
      history.each { |m| msgs << { 'role' => m['role'], 'content' => m['content'] } }
      msgs << { 'role' => 'user', 'content' => latest_user_text }
      msgs
    end

    def ai_demos_block_or_nil
      return nil if ai_demos_enabled?
      [404, { 'error' => 'AI demos disabled (set HOMURABI_ENABLE_AI_DEMOS=1 in wrangler vars)' }.to_json]
    end

    def ai_binding_block_or_nil
      return nil if ai_binding?
      [503, { 'error' => 'AI binding not configured (wrangler.toml [ai] block missing or wrangler version too old)' }.to_json]
    end

    def chat_verify_token!
      header = request.env['HTTP_AUTHORIZATION'].to_s
      parts = header.split(' ', 2)
      if parts.length != 2 || parts[0].downcase != 'bearer'
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      token = parts[1].strip
      if token.empty?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => 'missing bearer token' }.to_json }
      end
      verify_key = settings.jwt_secret
      algorithm  = settings.jwt_algorithm
      reason = nil
      decoded = begin
        JWT.decode(token, verify_key, true, algorithm: algorithm)
      rescue JWT::ExpiredSignature
        reason = 'token expired'
        nil
      rescue JWT::VerificationError
        reason = 'signature verification failed'
        nil
      rescue JWT::IncorrectAlgorithm
        reason = 'algorithm mismatch'
        nil
      rescue JWT::DecodeError => e
        reason = "invalid token: #{e.message}"
        nil
      rescue StandardError => e
        reason = "auth error: #{e.message}"
        nil
      end
      if decoded.nil?
        return { 'ok' => false, 'status' => 401,
                 'body' => { 'error' => 'unauthorized', 'reason' => reason || 'token verification failed' }.to_json }
      end
      payload, _header = decoded
      @jwt_payload = payload
      { 'ok' => true, 'payload' => payload }
    end
  end

  module ChatHistoryClassMethods
    def extract_ai_text(out)
      return out.to_s unless out.is_a?(Hash)
      if out['choices'].is_a?(Array) && !out['choices'].empty?
        msg = out['choices'][0].is_a?(Hash) ? out['choices'][0]['message'] : nil
        if msg.is_a?(Hash)
          c = msg['content']
          return c.to_s if c.is_a?(String) && !c.empty?
          r = msg['reasoning']
          return r.to_s if r.is_a?(String) && !r.empty?
        end
      end
      %w[response result output text].each do |k|
        v = out[k]
        return v.to_s if v.is_a?(String) && !v.empty?
      end
      ''
    end
  end
end
