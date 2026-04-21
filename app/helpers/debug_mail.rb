# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true

module Homurabi
  # Phase 17 — `/debug/mail` is open on localhost only; deployed Workers require session user App::DEBUG_MAIL_ADMIN_USERNAME.
  module DebugMailHelpers
    def debug_mail_local_request?
      h = request.host.to_s
      h == '127.0.0.1' || h == 'localhost'
    end

    # Returns a Rack triple [status, headers, body] when access must be denied, else nil.
    def debug_mail_gate_response
      return nil if debug_mail_local_request?
      return nil if current_session_user.to_s == App::DEBUG_MAIL_ADMIN_USERNAME

      body_str = debug_mail_forbidden_body
      [403, { 'Content-Type' => 'text/html; charset=utf-8', 'Content-Length' => body_str.bytesize.to_s }, [body_str]]
    end

    private

    def debug_mail_forbidden_body
      u = App::DEBUG_MAIL_ADMIN_USERNAME
      '<!DOCTYPE html><html lang="ja"><meta charset="utf-8"><title>403 Forbidden</title><body><p>/debug/mail はデプロイ環境ではログインユーザー <code>' + u.to_s + '</code> のみが利用できます（<a href="/login">ログイン</a>）。</p></body></html>'
    end
  end
end
