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
# homura: chain in `sinatra/cloudflare_workers`, which already pulls
# `cloudflare_workers` (runtime gem entry: BinaryBody, Rack handler,
# Cloudflare bindings) AND installs the at_exit hook that
# auto-registers `App` / `Sinatra::Application` with
# `Rack::Handler::CloudflareWorkers`. As of sinatra-homura 0.2.23 a
# modular app written the textbook way works on Workers without
# either `require 'sinatra/cloudflare_workers'` or `run App`:
#
#   require 'sinatra/base'
#   class App < Sinatra::Base
#     get '/' do; 'hi'; end
#   end
require 'sinatra/cloudflare_workers'
