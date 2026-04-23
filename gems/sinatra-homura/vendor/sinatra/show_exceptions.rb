# frozen_string_literal: true
#
# Phase 15-Pre (CPU budget): upstream `sinatra_upstream/show_exceptions` pulls in
# `rack/show_exceptions` with a large HTML error page template. homura runs in
# production-style Workers isolates and never relies on that HTML UI; we keep the
# middleware slot compatible with Sinatra's stack while making it a cheap pass-through.
#
# (Previously: `require 'sinatra_upstream/show_exceptions'`.)

module Sinatra
  class ShowExceptions
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    end
  end
end
