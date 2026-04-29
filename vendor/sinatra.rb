# frozen_string_literal: true
#
# homura entry-point for Sinatra.
#
# Phase 13: vendor/sinatra/ now tracks pristine upstream sinatra/sinatra
# v4.2.1 bit-identical to the GitHub tag. All Opal / Cloudflare Workers
# compatibility patches live in lib/sinatra_opal_patches.rb and are
# applied here after the upstream load completes. This keeps the diff
# between vendor/sinatra/ and upstream empty (trivial to bump on the
# next Sinatra release).

# Pre-load Opal compile-time shims for constants that upstream Sinatra
# references without `require`'ing (Gem::Version) or that Opal does
# not bundle from stdlib (IPAddr, rackup).
require 'rubygems/version'

require 'sinatra/main'
require 'sinatra_opal_patches'
# homura: classic-style `require 'sinatra'` is enough on its own.
# `sinatra/homura` chains in `homura/runtime` (the
# runtime gem entry: BinaryBody, Rack handler, Cloudflare bindings)
# AND eagerly installs the JS-side dispatcher so a fetch arriving
# before `run` was called (canonical sinatrarb.com snippet) still
# resolves the user's Sinatra app via `ensure_rack_app!`.
require 'sinatra/homura'

enable :inline_templates
