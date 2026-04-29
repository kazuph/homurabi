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
# `sinatra/homura` already chains in `homura/runtime`
# (the runtime gem entry — BinaryBody, Rack handler, Cloudflare
# bindings) and installs the at_exit hook that auto-registers
# `Sinatra::Application` (or `App` in modular code) with
# `Rack::Handler::Homura`. As of sinatra-homura 0.2.23 the
# user does NOT need to write `require 'sinatra/homura'`
# nor `run Sinatra::Application` — the canonical sinatrarb.com snippet
# works verbatim on Workers.
require 'sinatra/homura'

enable :inline_templates
