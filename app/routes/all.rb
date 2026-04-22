# await: true
# frozen_string_literal: true
# Routes are not `require`d here (Sinatra DSL needs `App` class scope).
# Source of truth: `canonical_all.rb` → `tools/split_routes_to_fragments.rb` → `fragments/`.
# Registration order matches `bootstrap.rb` (documentation) and `app/app.rb` (instance_eval loop).
