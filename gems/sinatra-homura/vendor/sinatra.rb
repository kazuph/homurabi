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
# homura: classic-style `require 'sinatra'` should be enough on its own;
# pull in the Cloudflare Workers runtime so users don't also have to
# `require 'sinatra/cloudflare_workers'` to get the Rack handler and
# Cloudflare bindings.
require 'cloudflare_workers'

enable :inline_templates
