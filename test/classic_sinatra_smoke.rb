# frozen_string_literal: true
# await: true
#
# Phase 13 regression harness: classic top-level Sinatra style.
#
# The existing smoke (test/smoke.rb) only exercises modular apps
# (`class App < Sinatra::Base; get '/' do ... end; end`). Codex review
# of Phase 13 uncovered that the Delegator.delegate override in
# lib/sinatra_opal_patches.rb was ineffective for methods already
# pre-defined by upstream base.rb's own `delegate :get, :enable, ...`
# call — classic `require 'sinatra'; get '/' do ... end` crashed on
# the first top-level `enable :inline_templates` with:
#
#   "super: no superclass method `enable' for main"
#
# This smoke runs the classic pattern through the dispatcher so that
# the Delegator instance methods are generated via the patched
# `delegate` body and not via the upstream pre-definition.

require 'json'
require 'sinatra'

# ---- Test assertions -----------------------------------------------
$passed = 0
$failed = 0

def ok(label, cond, note = nil)
  if cond
    $passed += 1
    puts "  PASS  #{label}"
  else
    $failed += 1
    puts "  FAIL  #{label}#{note ? " — #{note}" : ''}"
  end
end

puts '--- classic top-level Sinatra smoke ---'

# At this point vendor/sinatra.rb has already run:
#   require 'sinatra/main'
#   require 'sinatra_opal_patches'
#   enable :inline_templates
# If the Delegator fix is effective, that `enable` call succeeded.
ok 'enable :inline_templates reached (no NoMethodError)', true

# Top-level `get` / `post` — classic-mode DSL that routes through
# Sinatra::Delegator to Sinatra::Application.
get '/classic' do
  content_type 'text/plain'
  'classic hello'
end

post '/classic/echo' do
  content_type 'text/plain'
  request.body.rewind
  "echo: #{request.body.read}"
end

before do
  @seen = true
end

ok 'Sinatra::Application registered a route',
   Sinatra::Application.routes['GET'].any? { |r| r[0].match('/classic') }
ok 'Sinatra::Application registered POST /classic/echo',
   Sinatra::Application.routes['POST'].any? { |r| r[0].match('/classic/echo') }
ok 'before filter registered',
   !Sinatra::Application.filters[:before].empty?

# Exercise dispatch
status, headers, body = Sinatra::Application.call(
  'REQUEST_METHOD' => 'GET',
  'PATH_INFO' => '/classic',
  'QUERY_STRING' => '',
  'HTTP_HOST' => 'test.local',
  'rack.input' => StringIO.new('')
)

ok 'GET /classic returns 200', status == 200

# Copilot (PR #12) pointed out that `body.each { |b| @out = b }.then { true }`
# always evaluates truthy even if the block never fires. Collect the
# chunks into a plain String and assert equality so a broken body
# would actually fail this case.
#
# NOTE: intentionally do NOT call `body.close` — Sinatra's default
# middleware stack wires Rack::CommonLogger whose close hook calls
# `msg.gsub!` (`vendor/rack/common_logger.rb`), and Opal's Strings
# are immutable so `gsub!` raises NotImplementedError. That's a
# pre-existing gap unrelated to Phase 13 (the same logger is inert
# in the modular-app flow because body.close is called after the
# logger has already formatted the line — a race we avoid here).
collected = ''
if body.respond_to?(:each)
  body.each { |chunk| collected = collected + chunk.to_s }
end
ok '  — response body is "classic hello"',
   collected == 'classic hello',
   "got #{collected.inspect}"
ok '  — Content-Type is text/plain*', (headers['content-type'] || '').start_with?('text/plain')

# ---- Lazy-discovery regression (sinatra-homura 0.2.23) -----------------
# Classic-style apps are now allowed to omit the trailing
# `run Sinatra::Application` line. The flow that makes that work is:
#
#   1. `require 'sinatra'` triggers
#      `Rack::Handler::Homura.ensure_dispatcher_installed!`
#      so `globalThis.__HOMURA_RACK_DISPATCH__` is wired before any
#      fetch lands.
#   2. The first fetch reaches `Rack::Handler::Homura#call`
#      with `@app == nil`, which falls back to
#      `Sinatra::Homura.ensure_rack_app!` to discover the
#      classic `Sinatra::Application` (or modular `App`) at runtime.
#
# To exercise that without a real Workers fetch we clear the handler's
# cached `@app`, then call `ensure_rack_app!` directly and assert it
# registered `Sinatra::Application` (which already has routes from the
# classic `get '/classic' do … end` block above).
puts ''
puts '--- lazy first-fetch app discovery ---'

original_app = Rack::Handler::Homura.app
Rack::Handler::Homura.app = nil
ok '  — handler @app cleared for the test',
   Rack::Handler::Homura.app.nil?

discovered = Sinatra::Homura.ensure_rack_app!
ok '  — ensure_rack_app! discovers Sinatra::Application',
   discovered == Sinatra::Application,
   "got #{discovered.inspect}"
ok '  — handler.app now points at Sinatra::Application',
   Rack::Handler::Homura.app == Sinatra::Application

# Restore so the rest of the smoke-suite (if anything follows) sees the
# original handler state.
Rack::Handler::Homura.app = original_app if original_app

puts ''
puts "#{$passed + $failed} tests, #{$passed} passed, #{$failed} failed"
exit($failed == 0 ? 0 : 1)
