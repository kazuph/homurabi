# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 17 — Cloudflare Email Service (`SEND_EMAIL` binding).
#
#   Cloudflare::Email.new(env.SEND_EMAIL).send(
#     to: 'u@example.com',
#     from: 'noreply@yourdomain.com',
#     subject: 'Hello',
#     text: 'Plain body'
#   ).__await__
#
# See https://developers.cloudflare.com/email-service/api/send-emails/workers-api/

module Cloudflare
  class Email
    class Error < StandardError
      attr_reader :code

      def initialize(message, code: nil)
        @code = code
        super(message.to_s)
      end
    end

    attr_reader :js

    def initialize(js)
      @js = js
    end

    def available?
      js = @js
      !!`(#{js} !== null && #{js} !== undefined && #{js} !== Opal.nil)`
    end

    # Workers `env.SEND_EMAIL.send({ to, from, subject, text?, html?, replyTo? })`.
    # `to` / `from` / `reply_to` accept String, Hash ({ email:, name: }), or Arrays.
    # At least one of `text:` or `html:` is required.
    def send(to:, from:, subject:, text: nil, html: nil, reply_to: nil)
      js = @js
      err_klass = Cloudflare::Email::Error
      raise Error, 'send_email binding not bound' unless available?

      raise Error, 'subject is required' if subject.nil? || subject.to_s.strip.empty?

      has_text = !(text.nil? || text.to_s.empty?)
      has_html = !(html.nil? || html.to_s.empty?)
      raise Error, 'text or html is required' unless has_text || has_html

      payload = build_send_payload(to: to, from: from, subject: subject.to_s, text: text, html: html, reply_to: reply_to)

      `(async function(binding, payload, Kernel, Err) {
        try {
          var r = await binding.send(payload);
          if (r == null) return nil;
          var mid = r.messageId != null ? String(r.messageId) : '';
          return { message_id: mid };
        } catch (e) {
          var code = (e && e.code != null) ? String(e.code) : '';
          var msg = (e && e.message) ? String(e.message) : String(e);
          Kernel.$raise(Err.$new(msg, Opal.hash({ code: code })));
        }
      })(#{js}, #{payload}, #{Kernel}, #{err_klass})`
    end

    private

    def build_send_payload(to:, from:, subject:, text:, html:, reply_to:)
      obj = `({})`
      `#{obj}.subject = #{subject}`

      # --- to (string | string[]) -----------------------------------------
      to_js = normalize_to_js(to)
      `#{obj}.to = #{to_js}`

      # --- from -----------------------------------------------------------
      `#{obj}.from = #{normalize_from_js(from)}`

      `#{obj}.text = #{text}` if !(text.nil? || text.to_s.empty?)
      `#{obj}.html = #{html}` if !(html.nil? || html.to_s.empty?)

      # --- replyTo (camelCase in Workers API) -----------------------------
      rt_js = normalize_optional_reply_js(reply_to)
      `#{obj}.replyTo = #{rt_js}` unless rt_js.nil?

      obj
    end

    # Returns a JS array of email strings or a single string (API accepts both).
    def normalize_to_js(raw)
      emails = flatten_recipients(raw)
      raise Error, 'to is empty' if emails.empty?

      arr = `([])`
      emails.each { |e| `#{arr}.push(#{e})` }
      arr
    end

    def flatten_recipients(raw)
      case raw
      when nil
        []
      when String
        s = raw.strip
        s.empty? ? [] : [s]
      when Hash
        em = raw[:email] || raw['email']
        em.nil? ? [] : [em.to_s.strip].reject(&:empty?)
      when Array
        raw.flat_map { |x| flatten_recipients(x) }
      else
        s = raw.to_s.strip
        s.empty? ? [] : [s]
      end
    end

    def normalize_from_js(raw)
      normalize_address_js(raw)
    end

    def normalize_optional_reply_js(raw)
      return nil if raw.nil?
      return nil if raw.is_a?(Array) && raw.empty?
      return normalize_optional_reply_js(raw.first) if raw.is_a?(Array)

      normalize_address_js(raw)
    end

    # Returns a JS string ("a@b.com") or object { email, name }.
    def normalize_address_js(raw)
      case raw
      when String
        s = raw.strip
        raise Error, 'from address is empty' if s.empty?
        return s
      when Hash
        em = raw[:email] || raw['email']
        nm = raw[:name] || raw['name']
        raise Error, 'from.email is required' if em.nil? || em.to_s.strip.empty?
        js = `({})`
        `#{js}.email = #{em.to_s.strip}`
        `#{js}.name = #{nm.to_s}` unless nm.nil? || nm.to_s.strip.empty?
        js
      else
        normalize_address_js(raw.to_s)
      end
    end
  end
end
