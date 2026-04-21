# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true

module Homurabi
  # Phase 17 — `/debug/mail` is open on localhost only; deployed Workers require session user kazuph.
  module DebugMailHelpers
    def debug_mail_local_request?
      h = request.host.to_s
      h == '127.0.0.1' || h == 'localhost'
    end

    def debug_mail_require_kazuph!
      return if debug_mail_local_request?

      halt 403, debug_mail_forbidden_body unless current_session_user.to_s == App::DEBUG_MAIL_ADMIN_USERNAME
    end

    private

    def debug_mail_forbidden_body
      '<!DOCTYPE html><html lang="ja"><meta charset="utf-8"><title>403 Forbidden</title><body><p>/debug/mail はデプロイ環境ではログインユーザー <code>kazuph</code> のみが利用できます（<a href="/login">ログイン</a>）。</p></body></html>'
    end
  end
end
