# Minimal Digest stub for the homurabi Phase 2 hello-world handler.
# Opal stdlib does not ship a digest module. Real homurabi apps that
# need cryptographic hashing should use the Web Crypto API via the
# CloudflareWorkers adapter; this stub only exists so that
# `require 'digest/sha2'` (transitively pulled in by rack/etag and
# rack/session) does not fail at compile time. None of the methods
# below are reachable from the Phase 2 hello-world path.

module Digest
  class Class
    def self.hexdigest(*)
      raise NotImplementedError, 'Digest is stubbed in homurabi Phase 2'
    end

    def initialize
      @data = ''
    end

    def update(data)
      @data = @data + data.to_s
      self
    end

    def <<(data)
      update(data)
    end

    def hexdigest
      raise NotImplementedError, 'Digest is stubbed in homurabi Phase 2'
    end

    def digest
      raise NotImplementedError, 'Digest is stubbed in homurabi Phase 2'
    end

    def reset
      @data = ''
      self
    end
  end

  class Base < Class
  end

  # Concrete classes referenced by name at class-body time in gems.
  # Methods fall through to NotImplementedError, but the constants
  # have to exist so Ruby's constant lookup succeeds.
  class SHA1 < Class; end
  class MD5 < Class; end
end
