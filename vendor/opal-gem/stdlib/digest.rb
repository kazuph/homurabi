# frozen_string_literal: true
# backtick_javascript: true

require 'corelib/array/pack'
require 'corelib/string/unpack'
#
# homura patch — provide Ruby's `digest` stdlib on top of node:crypto.
#
# The homura runtime exposes node:crypto on globalThis before the Opal bundle
# boots, so standard-library style `require 'digest'` should resolve without
# extra gem-specific load path hacks.
#

module Digest
  class Base
    def initialize
      reset
    end

    def reset
      @hasher = `globalThis.__nodeCrypto__.createHash(#{self.class::ALGO})`
      self
    end

    def update(data)
      str = data.to_s
      `#{@hasher}.update(#{str}, 'utf8')`
      self
    end
    alias_method :<<, :update

    def hexdigest
      hasher = @hasher
      `#{hasher}.copy().digest('hex')`
    end

    def digest
      hex = hexdigest
      [hex].pack('H*')
    end

    def base64digest
      hasher = @hasher
      `#{hasher}.copy().digest('base64')`
    end

    def to_s
      hexdigest
    end

    def self.hexdigest(data)
      algo = self::ALGO
      str = data.to_s
      `globalThis.__nodeCrypto__.createHash(#{algo}).update(#{str}, 'utf8').digest('hex')`
    end

    def self.digest(data)
      hex = hexdigest(data)
      [hex].pack('H*')
    end

    def self.base64digest(data)
      algo = self::ALGO
      str = data.to_s
      `globalThis.__nodeCrypto__.createHash(#{algo}).update(#{str}, 'utf8').digest('base64')`
    end

    def self.file(*)
      raise NotImplementedError, 'Digest.file is unavailable on Cloudflare Workers (no filesystem)'
    end
  end

  Class = Base unless const_defined?(:Class)

  class SHA1 < Base
    ALGO = 'sha1'.freeze
  end

  class SHA256 < Base
    ALGO = 'sha256'.freeze
  end

  class SHA384 < Base
    ALGO = 'sha384'.freeze
  end

  class SHA512 < Base
    ALGO = 'sha512'.freeze
  end

  class MD5 < Base
    ALGO = 'md5'.freeze
  end
end
