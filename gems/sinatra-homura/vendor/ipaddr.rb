# frozen_string_literal: true
#
# homura Opal stub for ruby-ipaddr stdlib.
#
# Upstream Sinatra 4.x uses IPAddr only inside the `host_authorization`
# default (permitted_hosts patterns for development mode). homura
# overrides host_authorization to be empty in lib/sinatra_opal_patches.rb
# (we serve from fixed hosts under CF Workers, not arbitrary LANs),
# so IPAddr is never instantiated at runtime. This stub keeps the
# top-level `require 'ipaddr'` from failing at Opal compile time.

class IPAddr
  def initialize(_ = nil); end
end
