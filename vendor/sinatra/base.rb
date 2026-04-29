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
# homura: chain in `sinatra/homura` so a modular app
# written the textbook way works on Workers without an extra
# `require 'sinatra/homura'` line and without a
# trailing `run App` line.
require 'sinatra/homura'
