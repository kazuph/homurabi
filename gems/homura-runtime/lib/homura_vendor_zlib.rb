# frozen_string_literal: true

module Zlib
  class Error < StandardError; end

  class GzipFile
    class Error < Zlib::Error; end
    class CRCError < Error; end
    class LengthError < Error; end
    class NoFooter < Error; end
  end

  class GzipReader < GzipFile
    def self.wrap(*)
      raise NotImplementedError, 'Zlib stubbed'
    end
  end

  class GzipWriter < GzipFile
    def self.wrap(*)
      raise NotImplementedError, 'Zlib stubbed'
    end
  end

  class Deflate
    def self.deflate(*)
      raise NotImplementedError, 'Zlib stubbed'
    end

    def initialize(*); end

    def deflate(*)
      raise NotImplementedError, 'Zlib stubbed'
    end

    def finish
      raise NotImplementedError, 'Zlib stubbed'
    end

    def close; end
  end

  class Inflate
    def self.inflate(*)
      raise NotImplementedError, 'Zlib stubbed'
    end
  end

  DEFAULT_COMPRESSION = -1
  BEST_SPEED = 1
  BEST_COMPRESSION = 9
end
