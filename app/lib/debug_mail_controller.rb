# frozen_string_literal: true
#
# Phase 17 — `/debug/mail` の送信準備・結果整形（実際の `mail.send.__await__` はルート本体に置く。
# Opal は `# await:` ブロック外のヘルパー内では `.__await__` が Promise を解決しない)。

require 'json'

module Homurabi
  module DebugMailController
    class << self
      DEFAULT_TO = 'kazu.homma@gmail.com'

      SUBJECT_HAS_FULL_VERSION =
        /homurabi Phase 17 test.{0,3}Version\s+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      def parse_form_params(params, default_to: false)
        to = params['to'].to_s.strip
        to = DEFAULT_TO if default_to && to.empty?
        {
          to: to,
          subject: sanitize_form(params['subject'].to_s.strip),
          text: sanitize_form(params['text'].to_s),
          html: sanitize_form(params['html'].to_s)
        }
      end

      # バリデーション済みコンテキスト。`:error_result` があれば送信しない。
      def prepare_send(params, env, route)
        form = parse_form_params(params, default_to: false)
        mail_from = route.homurabi_mail_from
        final_to = form[:to].empty? ? DEFAULT_TO : form[:to]

        if mail_from.empty?
          return { error_result: error_result(form, mail_from, nil, 'HOMURABI_MAIL_FROM が未設定です。ドメイン onboarding 後に wrangler [vars] で verified の送信元アドレスを設定してください。') }
        end

        mail = route.send_email
        if mail.nil? || !mail.available?
          return { error_result: error_result(form, mail_from, nil, 'SEND_EMAIL バインディングが利用できません（wrangler.toml の [[send_email]] を確認）。') }
        end

        vid = vid_from_env(env)
        subject_line = resolve_subject_line(form[:subject], vid)
        text_body, html_body = resolve_bodies(form[:text], form[:html])

        {
          mail: mail,
          form: form,
          mail_from: mail_from,
          final_to: final_to,
          subject_line: subject_line,
          text_body: text_body,
          html_body: html_body
        }
      end

      def after_send_success(raw, ctx)
        form = ctx[:form]
        mail_from = ctx[:mail_from]
        final_to = ctx[:final_to]
        subject_line = ctx[:subject_line]

        if `(#{raw} == null || #{raw} === undefined || #{raw} === Opal.nil)`
          return error_result(form, mail_from, subject_line, 'SEND_EMAIL.send の戻りが null です。メールは送信されていません。')
        end

        message_id = extract_message_id(raw)
        cf_raw = extract_cf_raw(raw)
        success_result(form, mail_from, final_to, subject_line, message_id, cf_raw)
      end

      def after_send_failure(error, ctx)
        code = error.code.to_s
        error_result(ctx[:form], ctx[:mail_from], ctx[:subject_line], "#{code}: #{error.message}".strip)
      end

      private

      def sanitize_form(value)
        value.tr('+', ' ')
      end

      def vid_from_env(env)
        ray = env['HTTP_CF_RAY'].to_s.split('-').first
        ray.nil? || ray.empty? ? Time.now.to_i.to_s : ray
      end

      def resolve_subject_line(form_subject, vid)
        fs = form_subject.strip
        return "homurabi Phase 17 test — #{vid}" if fs.empty?
        return fs if fs =~ SUBJECT_HAS_FULL_VERSION

        "#{fs} — #{vid}"
      end

      def resolve_bodies(form_text, form_html)
        html = form_html.strip.empty? ? nil : form_html
        text = if form_text.strip.empty?
                 html ? nil : 'This is a test mail from homurabi'
               else
                 form_text
               end
        [text, html]
      end

      def extract_message_id(result)
        return '' unless result.respond_to?(:[])

        result['message_id'].to_s.strip
      end

      def extract_cf_raw(result)
        return '' unless result.respond_to?(:[])

        result['cf_send_result_json'].to_s
      end

      def success_result(form, mail_from, final_to, subject_line, message_id, cf_raw)
        accepted = !message_id.strip.empty?
        warning =
          if accepted
            nil
          else
            'message_id が空です。cf_send_result_json を確認してください。送信はキューに載っていない可能性があります。'
          end

        payload = {
          'ok' => accepted,
          'message_id' => message_id,
          'cf_send_result_json' => cf_raw,
          'to' => final_to,
          'from' => mail_from,
          'subject' => subject_line
        }
        payload['warning'] = warning if warning

        {
          ok: accepted,
          error: nil,
          warning: warning,
          message_id: message_id,
          raw_json: JSON.generate(payload),
          form: form,
          mail_from: mail_from
        }
      end

      def error_result(form, mail_from, subject_line, message)
        h = {
          ok: false,
          error: message,
          warning: nil,
          message_id: nil,
          raw_json: nil,
          form: form,
          mail_from: mail_from
        }
        h[:meta] = { subject_line: subject_line } if subject_line
        h
      end
    end
  end
end
