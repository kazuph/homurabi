# frozen_string_literal: true
# backtick_javascript: true

require 'corelib/array/pack'
require 'corelib/string/unpack'
#
# Phase 7 — Real Digest implementation backed by node:crypto.
#
# Replaces the Phase 2 NotImplementedError stub. All hash algos are
# synchronous (no Promise glue), enabled by importing node:crypto via
# src/setup-node-crypto.mjs and exposing it on globalThis.
#
# Available on:
#   - Cloudflare Workers (with `compatibility_flags = ["nodejs_compat"]`)
#   - Node.js (with `node --import ./src/setup-node-crypto.mjs`)
#
# Surface mirrors CRuby's `digest/sha1`, `digest/sha2`, `digest/md5`:
#
#   Digest::SHA256.hexdigest(str)            # one-shot hex
#   Digest::SHA256.digest(str)               # one-shot binary
#   Digest::SHA256.new.update(s).hexdigest   # streaming

module Digest
  # Common base class shared by SHA1 / SHA256 / SHA384 / SHA512 / MD5.
  # Subclasses define ALGO (the node:crypto algorithm name).
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
      str  = data.to_s
      `globalThis.__nodeCrypto__.createHash(#{algo}).update(#{str}, 'utf8').digest('hex')`
    end

    def self.digest(data)
      hex = hexdigest(data)
      [hex].pack('H*')
    end

    def self.base64digest(data)
      algo = self::ALGO
      str  = data.to_s
      `globalThis.__nodeCrypto__.createHash(#{algo}).update(#{str}, 'utf8').digest('base64')`
    end

    # Disk-backed digest is impossible on Workers (no FS).
    def self.file(*)
      raise NotImplementedError, 'Digest.file is unavailable on Cloudflare Workers (no filesystem)'
    end
  end

  # Backwards-compat alias for code that does `class Foo < Digest::Class`.
  Class = Base unless const_defined?(:Class)

  class SHA1   < Base; ALGO = 'sha1'.freeze;   end
  class SHA256 < Base; ALGO = 'sha256'.freeze; end
  class SHA384 < Base; ALGO = 'sha384'.freeze; end
  class SHA512 < Base; ALGO = 'sha512'.freeze; end
  class MD5    < Base; ALGO = 'md5'.freeze;    end
end
