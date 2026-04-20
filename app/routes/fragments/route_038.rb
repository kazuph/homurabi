# await: all, authenticate!, call, chat_verify_token!, clear_chat_history, decode, dh_compute_key, dispatch_js, dispatch_scheduled, encode, execute, execute_insert, fetch, fetch_raw, final, get_binary, get_first_row, get_response, list, load_chat_history, open, private_decrypt, public_encrypt, run, save_chat_history, send, sign, sign_pss, sleep, verify, verify_pss
# frozen_string_literal: true
# Route fragment 38 — test /test/ai
  get '/test/ai' do
    content_type 'application/json'
    unless ai_demos_enabled?
      status 404
      next({ 'error' => 'AI demos disabled (set HOMURABI_ENABLE_AI_DEMOS=1)' }.to_json)
    end
    unless ai_binding?
      status 503
      next({ 'error' => 'AI binding not bound (wrangler.toml [ai] block missing)' }.to_json)
    end

    cases = []
    primary  = CHAT_MODELS[:primary]
    fallback = CHAT_MODELS[:fallback]

    # NOTE: blocks-with-`__await__` compile to async functions in Opal
    # under `# await: true`. Iterators like `Array#each_with_index`
    # don't await each step, so any work the block kicks off races
    # against the JSON serialisation below — the route would return
    # `{cases: []}` before the AI call even finished. Inline a manual
    # loop where each step is followed by an explicit `__await__`.

    test_one = lambda { |model, label|
      result = begin
        out = Cloudflare::AI.run(model,
          { messages: [
            { role: 'system', content: 'reply with the single word READY' },
            { role: 'user',   content: 'ping' }
          ], max_tokens: 64 },
          binding: ai_binding
        )
        txt = App.extract_ai_text(out).strip
        if txt.empty?
          { 'pass' => false, 'note' => 'empty response from model' }
        else
          { 'pass' => true, 'note' => txt[0, 200] }
        end
      rescue ::Exception => e
        { 'pass' => false, 'note' => "#{e.class}: #{e.message[0, 200]}" }
      end
      result.merge('case' => label)
    }

    cases << test_one.call(primary,  "primary model #{primary} responds")
    cases << test_one.call(fallback, "fallback model #{fallback} responds")

    passed = cases.count { |c| c['pass'] }
    failed = cases.size - passed
    {
      'passed' => passed,
      'failed' => failed,
      'total'  => cases.size,
      'cases'  => cases
    }.to_json
  end
