# frozen_string_literal: true
#
# Registers `Sinatra::Inertia::Response`'s public methods as async sources
# for the homura `auto-await` analyzer. When this gem is consumed inside a
# homura Cloudflare Workers app, the analyzer sees `response.to_h` /
# `response.to_json` calls and inserts `__await__` automatically — that's
# how lazy/defer Procs returning JS Promises actually resolve before
# JSON-serialization.
#
# Loaded only when the homura runtime is present (MRI / pure-Sinatra
# environments don't need this; their `to_h` is fully synchronous).

if defined?(::CloudflareWorkers) && defined?(::CloudflareWorkers::AsyncRegistry)
  ::CloudflareWorkers::AsyncRegistry.register_async_source do
    async_method 'Sinatra::Inertia::Response', :to_h
    async_method 'Sinatra::Inertia::Response', :to_json
  end
end
