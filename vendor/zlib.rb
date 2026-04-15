# Minimal Zlib stub for the homurabi Phase 2 hello-world handler.
# Opal stdlib does not ship a zlib module. Real homurabi apps that need
# response compression should rely on the Cloudflare edge to gzip
# responses on the way out. This stub only exists so that
# `require 'zlib'` (transitively pulled in by rack/deflater) does not
# fail at compile time. None of the methods below are reachable from
# the Phase 2 hello-world path.

module Zlib
  class Error < StandardError; end
  class GzipFile
    class Error < Zlib::Error; end
    class CRCError < Error; end
    class LengthError < Error; end
    class NoFooter < Error; end
  end

  class GzipReader < GzipFile
    def self.wrap(*); raise NotImplementedError, 'Zlib stubbed'; end
  end

  class GzipWriter < GzipFile
    def self.wrap(*); raise NotImplementedError, 'Zlib stubbed'; end
  end

  class Deflate
    def self.deflate(*); raise NotImplementedError, 'Zlib stubbed'; end
    def initialize(*); end
    def deflate(*); raise NotImplementedError, 'Zlib stubbed'; end
    def finish; raise NotImplementedError, 'Zlib stubbed'; end
    def close; end
  end

  class Inflate
    def self.inflate(*); raise NotImplementedError, 'Zlib stubbed'; end
  end

  DEFAULT_COMPRESSION = -1
  BEST_SPEED = 1
  BEST_COMPRESSION = 9
end
