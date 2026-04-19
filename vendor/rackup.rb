# frozen_string_literal: true
#
# homurabi Opal stub for ruby-rackup gem.
#
# Upstream Sinatra 4.x attempts `begin; require 'rackup'; rescue LoadError; end`
# to pick up a Rackup::Handler when `Sinatra::Base.run!` is called for
# self-hosted-server mode. We never use `.run!` (we run inside the
# Cloudflare Workers dispatcher), but Opal's static require resolver
# can't see that the upstream `require 'rackup'` is guarded by
# `rescue LoadError`, so it fails at compile time. This empty stub
# makes the require resolve to a no-op.
