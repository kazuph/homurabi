source "https://rubygems.org"

ruby "3.4.9"

# Root Gemfile — gem development workspace.
# This is the dev-mode Bundler context for the homura monorepo
# itself: running `npm test` (gem smoke + ruby tests under test/),
# rebuilding the test bundles via `bin/opal-test-build`, and any other
# gem-side tooling. The canonical site lives under `site/` with its
# own `Gemfile` for the deployed application.
#
# Opal: Ruby -> JavaScript source-to-source compiler.
# The monorepo builds against the vendored homura Opal fork directly.
# That fork release is 1.8.3.rc1.3, still based on upstream Opal 1.8.3.rc1.
gem "opal-homura", path: "vendor/opal-gem", require: "opal"
gem "homura-runtime", path: "gems/homura-runtime"
gem "sinatra-homura", path: "gems/sinatra-homura"
gem "sequel-d1", path: "gems/sequel-d1"
gem "syntax_tree", require: false
