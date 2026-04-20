# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Routes are not `require`d here (Sinatra DSL needs `App` class scope).
# Source of truth: `canonical_all.rb` → `tools/split_routes_to_fragments.rb` → `fragments/`.
# Registration order matches `bootstrap.rb` (documentation) and `app/app.rb` (instance_eval loop).
