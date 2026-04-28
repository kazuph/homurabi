# frozen_string_literal: true
#
# homura Phase 13 — Sinatra::Base loader wrapper.
#
# vendor/sinatra_upstream/ holds pristine upstream sinatra/sinatra
# v4.2.1. This file loads upstream unchanged, then applies every
# Opal / Cloudflare Workers deviation from one place
# (lib/sinatra_opal_patches.rb).

require 'sinatra_upstream/base'
require 'sinatra_opal_patches'
# homura: pull in the Cloudflare Workers runtime (BinaryBody, Rack
# handler, Cloudflare bindings) here too, so a modular app written
# the textbook way — `require 'sinatra/base'` followed by
# `class App < Sinatra::Base` — works on Workers without an extra
# `require 'sinatra/cloudflare_workers'` line.
require 'cloudflare_workers'
