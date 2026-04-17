# frozen_string_literal: true
# backtick_javascript: true
# await: true
#
# Phase 7 — OpenSSL surface backed by node:crypto AND Web Crypto.
#
# Cloudflare Workers' nodejs_compat layer (unenv) currently implements
# only a subset of node:crypto:
#   ✓ createHash / createHmac / randomBytes / randomUUID
#   ✓ pbkdf2Sync / hkdfSync
#   ✓ generateKeyPairSync / createPrivateKey / createPublicKey
#   ✗ createCipheriv / createDecipheriv  → use Web Crypto SubtleCrypto
#   ✗ createSign / createVerify          → use Web Crypto SubtleCrypto
#
# The methods that *need* SubtleCrypto are async by nature, so we wrap
# them in `# await: true` + `.__await__` (the same pattern D1/KV/R2 use).
# Caller code must add `.__await__` on Cipher#update / #final and
# PKey#sign / #verify; everything else (Hash, HMAC, KDF, key gen,
# PEM I/O) stays synchronous.
#
# Goal: cover the OpenSSL APIs that idiomatic Ruby code (jwt, rack
# session encryption, devise-style password hashing, generic crypto)
# exercises, using the synchronous node:crypto module exposed on
# globalThis by src/setup-node-crypto.mjs.
#
# Sync-only: every method completes in the calling V8 microtask, no
# Promise glue. This is what lets jwt-gem-style code "just work"
# without per-call `.__await__`.
#
# Not implemented (out of scope for Phase 7):
#   - SMIME / PKCS7 / X509 certificate handling
#   - OpenSSL::SSL (Workers has fetch() for HTTPS instead)
#   - Engine / Config introspection
# These can be layered on later if a vendored gem demands them.

require 'corelib/array/pack'
require 'corelib/string/unpack'
require 'digest'
require 'base64'

module OpenSSL
  # =================================================================
  # OpenSSL::Digest — thin wrapper that mirrors CRuby's class hierarchy
  # so jwt and friends can pass either a String name ("SHA256") or a
  # `OpenSSL::Digest::SHA256.new` instance interchangeably.
  # =================================================================
  class Digest < ::Digest::Base
    # OpenSSL::Digest.new('SHA256') — accepts a string algorithm name.
    def self.new(name = nil)
      if self == OpenSSL::Digest && name
        klass = const_get(name.to_s.upcase)
        return klass.new
      end
      super()
    end

    # The string name node:crypto / OpenSSL expect for this digest.
    def self.algorithm_name
      self::ALGO
    end

    def name
      self.class.algorithm_name.upcase
    end

    class SHA1   < OpenSSL::Digest; ALGO = 'sha1'.freeze;   end
    class SHA256 < OpenSSL::Digest; ALGO = 'sha256'.freeze; end
    class SHA384 < OpenSSL::Digest; ALGO = 'sha384'.freeze; end
    class SHA512 < OpenSSL::Digest; ALGO = 'sha512'.freeze; end
    class MD5    < OpenSSL::Digest; ALGO = 'md5'.freeze;    end
  end

  # Resolve a digest spec (String, Symbol, OpenSSL::Digest instance, or
  # OpenSSL::Digest class) to the lowercase node:crypto algorithm name.
  def self.normalize_digest(spec)
    case spec
    when ::String, ::Symbol then spec.to_s.downcase
    else
      if spec.respond_to?(:name)
        spec.name.to_s.downcase
      elsif spec.respond_to?(:algorithm_name)
        spec.algorithm_name.to_s.downcase
      elsif spec.is_a?(::Class) && spec < ::Digest::Base
        spec::ALGO.to_s.downcase
      else
        spec.to_s.downcase
      end
    end
  end

  # =================================================================
  # OpenSSL::HMAC
  # =================================================================
  module HMAC
    # Returns the binary digest as a Ruby String.
    def self.digest(digest_spec, key, data)
      algo = OpenSSL.normalize_digest(digest_spec)
      key  = key.to_s
      data = data.to_s
      hex  = `globalThis.__nodeCrypto__.createHmac(#{algo}, Buffer.from(#{key}, 'utf8')).update(Buffer.from(#{data}, 'utf8')).digest('hex')`
      [hex].pack('H*')
    end

    # Returns the lowercase hex digest as a Ruby String.
    def self.hexdigest(digest_spec, key, data)
      algo = OpenSSL.normalize_digest(digest_spec)
      key  = key.to_s
      data = data.to_s
      `globalThis.__nodeCrypto__.createHmac(#{algo}, Buffer.from(#{key}, 'utf8')).update(Buffer.from(#{data}, 'utf8')).digest('hex')`
    end

    # Returns the base64-encoded digest as a Ruby String.
    def self.base64digest(digest_spec, key, data)
      algo = OpenSSL.normalize_digest(digest_spec)
      key  = key.to_s
      data = data.to_s
      `globalThis.__nodeCrypto__.createHmac(#{algo}, Buffer.from(#{key}, 'utf8')).update(Buffer.from(#{data}, 'utf8')).digest('base64')`
    end
  end

  # =================================================================
  # OpenSSL::Cipher — Web Crypto SubtleCrypto backend.
  #
  # All input and output is **byte-transparent** Ruby Strings (one
  # byte per JS char, values 0..255). Plaintext / ciphertext are
  # treated as raw bytes; the caller controls any text encoding.
  #
  # Mode-specific behavior:
  #   - **AES-CTR**: true streaming — `update(chunk)` returns
  #     ciphertext for the leading 16-byte multiple of the buffered
  #     bytes immediately, with the rest carried into the next call.
  #     The Web Crypto counter increments automatically per block.
  #   - **AES-GCM**: buffered; `update` returns "" and `final` emits
  #     the entire ciphertext + sets `auth_tag`. (GCM tag depends on
  #     all bytes; this matches CRuby's effective behavior.)
  #   - **AES-CBC**: buffered; Web Crypto AES-CBC enforces PKCS#7
  #     padding atomically, so streaming is not possible at the JS
  #     API level. `final` emits the full padded ciphertext.
  #
  # update / final are async (Promise → caller .__await__) for any
  # mode that calls Subtle.
  # =================================================================
  class Cipher
    class CipherError < StandardError; end

    ALGORITHMS = {
      'aes-128-gcm' => { subtle: 'AES-GCM', key_len: 16, iv_len: 12 },
      'aes-192-gcm' => { subtle: 'AES-GCM', key_len: 24, iv_len: 12 },
      'aes-256-gcm' => { subtle: 'AES-GCM', key_len: 32, iv_len: 12 },
      'aes-128-cbc' => { subtle: 'AES-CBC', key_len: 16, iv_len: 16 },
      'aes-192-cbc' => { subtle: 'AES-CBC', key_len: 24, iv_len: 16 },
      'aes-256-cbc' => { subtle: 'AES-CBC', key_len: 32, iv_len: 16 },
      'aes-128-ctr' => { subtle: 'AES-CTR', key_len: 16, iv_len: 16 },
      'aes-192-ctr' => { subtle: 'AES-CTR', key_len: 24, iv_len: 16 },
      'aes-256-ctr' => { subtle: 'AES-CTR', key_len: 32, iv_len: 16 }
    }.freeze

    attr_reader :name

    def initialize(name)
      @name = name.to_s.downcase
      meta = ALGORITHMS[@name]
      raise CipherError, "unsupported cipher: #{name}" unless meta
      @subtle_name = meta[:subtle]
      @key_len = meta[:key_len]
      @iv_len  = meta[:iv_len]
      @mode    = nil
      @key     = nil
      @iv      = nil
      @aad     = nil
      @auth_tag = nil
      @input_buffer = ''
      @ctr_pending  = ''   # leftover bytes < 16 between CTR update calls
      @ctr_block_count = 0 # blocks already consumed (for counter increment)
      @finalized = false
    end

    def encrypt; @mode = :encrypt; self; end
    def decrypt; @mode = :decrypt; self; end
    def key=(v); @key = v.to_s; self; end
    def iv=(v);  @iv  = v.to_s; self; end
    def auth_data=(v); @aad = v.to_s; self; end
    def auth_tag=(v);  @auth_tag = v.to_s; self; end

    def auth_tag(_len = 16)
      raise CipherError, 'auth_tag only valid after encrypt + final (GCM only)' if @auth_tag.nil?
      @auth_tag
    end

    def random_key; @key = ::SecureRandom.random_bytes(@key_len); end
    def random_iv;  @iv  = ::SecureRandom.random_bytes(@iv_len);  end
    def key_len; @key_len; end
    def iv_len;  @iv_len;  end

    # update — for AES-CTR returns ciphertext for whole 16-byte
    # blocks immediately; for GCM/CBC buffers and returns "".
    def update(data)
      raise CipherError, 'cannot update after final' if @finalized
      raise CipherError, 'key not set' if @key.nil?
      raise CipherError, 'iv not set'  if @iv.nil?
      raise CipherError, 'mode not set' if @mode.nil?

      str = data.to_s
      if ctr?
        ctr_update_stream(str)
      else
        @input_buffer = @input_buffer + str
        ''
      end
    end

    def final
      raise CipherError, 'key not set' if @key.nil?
      raise CipherError, 'iv not set'  if @iv.nil?
      raise CipherError, 'mode not set' if @mode.nil?
      @finalized = true

      if ctr?
        ctr_final
      elsif gcm?
        gcm_finalize_buffer
      elsif cbc?
        cbc_finalize_buffer
      else
        raise CipherError, "unknown mode: #{@subtle_name}"
      end
    end

    private

    def gcm?; @subtle_name == 'AES-GCM'; end
    def cbc?; @subtle_name == 'AES-CBC'; end
    def ctr?; @subtle_name == 'AES-CTR'; end

    def u8_to_binstr(u8)
      hex = `(function(u8) { var s=''; for (var i=0;i<u8.length;i++) { var h=u8[i].toString(16); if (h.length<2) h='0'+h; s+=h; } return s; })(#{u8})`
      [hex].pack('H*')
    end

    # ----- CTR true streaming --------------------------------------
    # Each call processes (pending + new) bytes by emitting all
    # complete 16-byte blocks immediately, deferring the tail.
    def ctr_update_stream(new_data)
      bytes = @ctr_pending + new_data
      full_size = (bytes.bytesize / 16) * 16
      return '' if full_size == 0 && (@ctr_pending = bytes) && true   # no full blocks yet
      block_data = bytes[0, full_size]
      @ctr_pending = bytes.bytesize > full_size ? bytes[full_size, bytes.bytesize - full_size] : ''
      run_ctr_subtle(block_data, @ctr_block_count).tap {
        @ctr_block_count += full_size / 16
      }
    end

    def ctr_final
      # XOR-encrypt remaining tail (if any). For AES-CTR, the last
      # partial block is just XORed against the last counter's
      # keystream — Subtle handles that when given a partial input.
      if @ctr_pending.bytesize > 0
        out = run_ctr_subtle(@ctr_pending, @ctr_block_count)
        @ctr_block_count += (@ctr_pending.bytesize + 15) / 16
        @ctr_pending = ''
        out
      else
        ''
      end
    end

    def run_ctr_subtle(data, block_offset)
      # Construct the 128-bit counter = iv (16 bytes) + block_offset.
      # We use a Subtle counter length of 64 bits (low 64 bits change).
      key_bytes = @key
      iv  = @iv
      offset = block_offset
      promise = `(async function() {
        var subtle = globalThis.crypto.subtle;
        var keyObj = await subtle.importKey('raw', Opal.binstr_to_u8(#{key_bytes}), { name: 'AES-CTR' }, false, ['encrypt', 'decrypt']);
        var counter = Opal.binstr_to_u8(#{iv}).slice();
        // Add offset to the low-64 bits, big-endian
        var lo = BigInt(#{offset}) + ((BigInt(counter[8]) << 56n) | (BigInt(counter[9]) << 48n) | (BigInt(counter[10]) << 40n) | (BigInt(counter[11]) << 32n) | (BigInt(counter[12]) << 24n) | (BigInt(counter[13]) << 16n) | (BigInt(counter[14]) << 8n) | BigInt(counter[15]));
        for (var i = 15; i >= 8; i--) {
          counter[i] = Number(lo & 0xffn);
          lo = lo >> 8n;
        }
        var ct = await subtle.encrypt({ name: 'AES-CTR', counter: counter, length: 64 }, keyObj, Opal.binstr_to_u8(#{data}));
        return new Uint8Array(ct);
      })()`
      u8 = promise.__await__
      u8_to_binstr(u8)
    end

    # ----- GCM finalize (single-shot) ------------------------------
    def gcm_finalize_buffer
      key    = @key
      iv     = @iv
      aad    = @aad
      tag    = @auth_tag
      buffer = @input_buffer
      mode   = @mode

      if mode == :encrypt
        out_promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var algo = { name: 'AES-GCM', iv: Opal.binstr_to_u8(#{iv}), tagLength: 128 };
          if (#{aad} !== nil && #{aad} != null) algo.additionalData = Opal.binstr_to_u8(#{aad});
          var subtleKey = await subtle.importKey('raw', Opal.binstr_to_u8(#{key}), { name: 'AES-GCM' }, false, ['encrypt']);
          var ct = await subtle.encrypt(algo, subtleKey, Opal.binstr_to_u8(#{buffer}));
          return new Uint8Array(ct);
        })()`
        ct_u8 = out_promise.__await__
        ct_bin = u8_to_binstr(ct_u8)
        # Tag is the last 16 bytes
        @auth_tag = ct_bin[ct_bin.bytesize - 16, 16]
        ct_bin[0, ct_bin.bytesize - 16]
      else
        ct_in = tag ? buffer + tag : buffer
        out_promise = `(async function() {
          try {
            var subtle = globalThis.crypto.subtle;
            var algo = { name: 'AES-GCM', iv: Opal.binstr_to_u8(#{iv}), tagLength: 128 };
            if (#{aad} !== nil && #{aad} != null) algo.additionalData = Opal.binstr_to_u8(#{aad});
            var subtleKey = await subtle.importKey('raw', Opal.binstr_to_u8(#{key}), { name: 'AES-GCM' }, false, ['decrypt']);
            var pt = await subtle.decrypt(algo, subtleKey, Opal.binstr_to_u8(#{ct_in}));
            return new Uint8Array(pt);
          } catch (e) { throw new Error('GCM decrypt: ' + (e.message || String(e))); }
        })()`
        begin
          u8_to_binstr(out_promise.__await__)
        rescue ::Exception => e
          raise CipherError, e.message
        end
      end
    end

    # ----- CBC finalize (single-shot, PKCS#7) ----------------------
    def cbc_finalize_buffer
      key    = @key
      iv     = @iv
      buffer = @input_buffer
      mode   = @mode

      if mode == :encrypt
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var subtleKey = await subtle.importKey('raw', Opal.binstr_to_u8(#{key}), { name: 'AES-CBC' }, false, ['encrypt']);
          var ct = await subtle.encrypt({ name: 'AES-CBC', iv: Opal.binstr_to_u8(#{iv}) }, subtleKey, Opal.binstr_to_u8(#{buffer}));
          return new Uint8Array(ct);
        })()`
        u8_to_binstr(promise.__await__)
      else
        promise = `(async function() {
          try {
            var subtle = globalThis.crypto.subtle;
            var subtleKey = await subtle.importKey('raw', Opal.binstr_to_u8(#{key}), { name: 'AES-CBC' }, false, ['decrypt']);
            var pt = await subtle.decrypt({ name: 'AES-CBC', iv: Opal.binstr_to_u8(#{iv}) }, subtleKey, Opal.binstr_to_u8(#{buffer}));
            return new Uint8Array(pt);
          } catch (e) { throw new Error('CBC decrypt: ' + (e.message || String(e))); }
        })()`
        begin
          u8_to_binstr(promise.__await__)
        rescue ::Exception => e
          raise CipherError, e.message
        end
      end
    end
  end

  # Tiny helper used by Cipher to convert a Ruby binary String (one
  # byte per char, 0..255) to a JS Uint8Array. Defined on Opal so it's
  # reachable from backtick blocks above.
  `Opal.binstr_to_u8 = function(s) { var u = new Uint8Array(s.length); for (var i=0;i<s.length;i++) { u[i] = s.charCodeAt(i) & 0xff; } return u; }`

  # =================================================================
  # OpenSSL::BN — BigNum backed by JS BigInt.
  #
  # Supports CRuby's commonly-used arithmetic (+ - * / %, comparison,
  # ** mod, gcd, num_bits / num_bytes, to_s in any radix). Internally
  # we hold the value as a JS BigInt for unbounded precision.
  # =================================================================
  class BN
    include Comparable

    def self.new(arg = nil)
      instance = allocate
      instance.send(:initialize, arg)
      instance
    end

    def initialize(arg = 0)
      case arg
      when ::Integer
        @big = `BigInt(#{arg.to_s})`
      when ::String
        s = arg.strip
        if s.empty?
          @big = `0n`
        elsif s.start_with?('0x') || s.start_with?('0X')
          @big = `BigInt(#{s})`
        elsif s.match?(/\A\h+\z/) && (s.length.even? || s.length > 18)
          # Heuristic: pure-hex string of even length → treat as hex.
          @big = `BigInt('0x' + #{s})`
        else
          @big = `BigInt(#{s})`
        end
      when BN
        @big = arg.instance_variable_get(:@big)
      when nil
        @big = `0n`
      else
        @big = `BigInt(#{arg.to_s})`
      end
      @bits = nil
      @jwk_n = nil
    end

    def num_bits
      return @bits if @bits
      `(function(b) { if (b === 0n) return 0; var n = b < 0n ? -b : b; var c = 0; while (n > 0n) { c += 1; n >>= 1n; } return c; })(#{@big})`
    end

    def num_bytes
      (num_bits + 7) / 8
    end

    def to_s(radix = 10)
      `#{@big}.toString(#{radix})`
    end

    def to_i
      to_s(10).to_i
    end

    def +(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} + #{coerce_big(other)}`) }; end
    def -(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} - #{coerce_big(other)}`) }; end
    def *(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} * #{coerce_big(other)}`) }; end
    def /(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} / #{coerce_big(other)}`) }; end
    def %(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} % #{coerce_big(other)}`) }; end
    def **(other); BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} ** #{coerce_big(other)}`) }; end
    def -@;        BN.new(0).tap { |b| b.instance_variable_set(:@big, `-(#{@big})`) }; end
    def abs;       BN.new(0).tap { |b| b.instance_variable_set(:@big, `#{@big} < 0n ? -(#{@big}) : #{@big}`) }; end

    def <=>(other)
      o = coerce_big(other)
      `#{@big} < #{o} ? -1 : (#{@big} > #{o} ? 1 : 0)`
    end

    def ==(other)
      return false unless other.is_a?(BN) || other.is_a?(::Integer) || other.is_a?(::String)
      `#{@big} === #{coerce_big(other)}`
    end
    alias_method :eql?, :==

    def hash
      to_s.hash
    end

    # Modular exponentiation: self^exp mod m
    def mod_exp(exp, m)
      r = `(function(b, e, m) { var r = 1n; b = b % m; while (e > 0n) { if (e & 1n) r = (r * b) % m; e >>= 1n; b = (b * b) % m; } return r; })(#{@big}, #{coerce_big(exp)}, #{coerce_big(m)})`
      BN.new(0).tap { |b| b.instance_variable_set(:@big, r) }
    end

    # Greatest common divisor (Euclidean)
    def gcd(other)
      r = `(function(a, b) { a = a < 0n ? -a : a; b = b < 0n ? -b : b; while (b !== 0n) { var t = b; b = a % b; a = t; } return a; })(#{@big}, #{coerce_big(other)})`
      BN.new(0).tap { |b| b.instance_variable_set(:@big, r) }
    end

    def odd?;  `(#{@big} & 1n) === 1n` end
    def even?; `(#{@big} & 1n) === 0n` end
    def zero?; `#{@big} === 0n` end
    def negative?; `#{@big} < 0n` end
    def positive?; `#{@big} > 0n` end

    private

    def coerce_big(other)
      case other
      when BN then other.instance_variable_get(:@big)
      when ::Integer then `BigInt(#{other.to_s})`
      when ::String then `BigInt(#{other})`
      else `BigInt(#{other.to_s})`
      end
    end
  end

  # =================================================================
  # OpenSSL::PKey
  #
  # All sign / verify / dh_compute_key methods are async because they
  # go through Web Crypto SubtleCrypto (Workers' nodejs_compat doesn't
  # implement node:crypto.createSign / publicEncrypt with all paddings
  # yet). Caller adds `.__await__` exactly like with D1/KV/R2.
  #
  # Design note: verify() raises on key/algo / decoding errors and
  # returns true/false ONLY for valid signature mismatch. This matches
  # CRuby. Catch-all `rescue` is intentional only for verify_raw vs
  # verify_der mode mismatches that the caller may legitimately retry.
  # =================================================================
  module PKey
    class PKeyError < StandardError; end

    # Number of bytes per coordinate for each named curve. Used by
    # ECDSA raw R||S ↔ DER conversion to know the fixed-width R / S
    # encoding the JWT spec requires.
    EC_CURVE_SIZE = {
      'P-256'      => 32,
      'prime256v1' => 32,
      'P-384'      => 48,
      'secp384r1'  => 48,
      'P-521'      => 66,
      'secp521r1'  => 66
    }.freeze

    class PKey
      attr_reader :js_private, :js_public, :pem

      private

      def u8_to_binstr(u8)
        hex = `(function(u8) { var s=''; for (var i=0;i<u8.length;i++) { var h=u8[i].toString(16); if (h.length<2) h='0'+h; s+=h; } return s; })(#{u8})`
        [hex].pack('H*')
      end

      # Convert "SHA256" / :sha256 / OpenSSL::Digest::SHA256.new to the
      # subtle Web Crypto algorithm name "SHA-256".
      def canonical_hash(name)
        case OpenSSL.normalize_digest(name).to_s
        when 'sha1'   then 'SHA-1'
        when 'sha256' then 'SHA-256'
        when 'sha384' then 'SHA-384'
        when 'sha512' then 'SHA-512'
        else
          raise PKeyError, "unsupported hash: #{name.inspect}"
        end
      end

      def digest_byte_length(canonical_name)
        case canonical_name
        when 'SHA-1'   then 20
        when 'SHA-256' then 32
        when 'SHA-384' then 48
        when 'SHA-512' then 64
        else
          raise PKeyError, "unknown digest: #{canonical_name}"
        end
      end

      # Run a Web Crypto subtle operation in an IIFE; importKey errors
      # are re-raised as Ruby exceptions, while a bool from verify is
      # returned as-is.
      def run_subtle(label, &js_builder)
        raise PKeyError, 'run_subtle requires a JS builder' unless js_builder
        # not used currently — placeholder for refactor extraction
      end
    end

    # ---------------------------------------------------------------
    # OpenSSL::PKey::RSA — RS, PS algos + OAEP via Web Crypto subtle
    # ---------------------------------------------------------------
    class RSA < PKey
      def self.new(arg = nil)
        instance = allocate
        instance.send(:setup, arg)
        instance
      end

      def self.generate(bits = 2048)
        new(bits.to_i)
      end

      def setup(arg)
        if arg.is_a?(Integer)
          bits = arg
          pair = `(function() {
            var p = globalThis.__nodeCrypto__.generateKeyPairSync('rsa', { modulusLength: #{bits} });
            return { priv: p.privateKey, pub: p.publicKey };
          })()`
          @js_private = `#{pair}.priv`
          @js_public  = `#{pair}.pub`
        else
          pem_str = arg.to_s
          loaded = `(function() {
            var pem = #{pem_str};
            try {
              var priv = globalThis.__nodeCrypto__.createPrivateKey(pem);
              var pub  = globalThis.__nodeCrypto__.createPublicKey(priv);
              return { priv: priv, pub: pub };
            } catch (e1) {
              try {
                var pub2 = globalThis.__nodeCrypto__.createPublicKey(pem);
                return { priv: null, pub: pub2 };
              } catch (e2) {
                throw new Error('PKey::RSA: cannot parse key: ' + (e1.message || e2.message));
              }
            }
          })()`
          @js_private = `#{loaded}.priv`
          @js_public  = `#{loaded}.pub`
        end
      end

      def private?
        !`#{@js_private} == null`
      end

      def public_key
        new_pub = self.class.allocate
        new_pub.instance_variable_set(:@js_public, @js_public)
        new_pub.instance_variable_set(:@js_private, nil)
        new_pub
      end

      def to_pem
        if @js_private
          priv = @js_private
          `#{priv}.export({ type: 'pkcs8', format: 'pem' })`
        else
          pub = @js_public
          `#{pub}.export({ type: 'spki', format: 'pem' })`
        end
      end

      # OpenSSL::BN for the RSA modulus n.
      def n
        pub = @js_public || @js_private
        jwk_n = `#{pub}.export({ format: 'jwk' }).n || ''`
        BN.new(jwk_b64u_to_hex(jwk_n))
      end

      # OpenSSL::BN for the RSA public exponent e (typically 65537).
      def e
        pub = @js_public || @js_private
        jwk_e = `#{pub}.export({ format: 'jwk' }).e || 'AQAB'`
        BN.new(jwk_b64u_to_hex(jwk_e))
      end

      private

      def jwk_b64u_to_hex(jwk_field)
        b64 = jwk_field.to_s.tr('-_', '+/')
        b64 = b64 + ('=' * ((4 - b64.length % 4) % 4))
        bin = ::Base64.decode64(b64)
        '0x' + bin.unpack1('H*')
      end

      public

      # ----- RSASSA-PKCS1-v1_5 (RS256/384/512) -----------------------
      def sign(digest_spec, data)
        raise PKeyError, 'private key required' unless @js_private
        hash = canonical_hash(digest_spec)
        priv = @js_private
        str  = data.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var der, key, sig;
          try {
            der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            key = await subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: { name: #{hash} } }, false, ['sign']);
          } catch (e) { throw new Error('PKey::RSA#sign: import: ' + (e.message || String(e))); }
          try {
            sig = await subtle.sign('RSASSA-PKCS1-v1_5', key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('PKey::RSA#sign: sign: ' + (e.message || String(e))); }
          return new Uint8Array(sig);
        })()`
        u8_to_binstr(promise.__await__)
      end

      def verify(digest_spec, signature, data)
        verify_subtle('RSASSA-PKCS1-v1_5', digest_spec, signature, data, 'RSASSA-PKCS1-v1_5')
      end

      # ----- RSASSA-PSS (PS256/384/512) ------------------------------
      # CRuby: rsa.sign_pss(digest, data, salt_length: :digest, mgf1_hash: 'SHA256')
      # salt_length symbol :digest = use digest byte length (most JWT impls)
      # salt_length symbol :max    = use maximum (modulus_bytes - digest - 2)
      # mgf1_hash is fixed to the same digest in Web Crypto subtle.
      def sign_pss(digest_spec, data, salt_length: :digest, mgf1_hash: nil)
        raise PKeyError, 'private key required' unless @js_private
        hash = canonical_hash(digest_spec)
        if mgf1_hash && canonical_hash(mgf1_hash) != hash
          raise PKeyError, "Web Crypto only supports MGF1 with the same hash as the message digest (#{hash})"
        end
        salt_len = pss_salt_length(salt_length, hash)
        priv = @js_private
        str  = data.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var der, key, sig;
          try {
            der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            key = await subtle.importKey('pkcs8', der, { name: 'RSA-PSS', hash: { name: #{hash} } }, false, ['sign']);
          } catch (e) { throw new Error('PKey::RSA#sign_pss: import: ' + (e.message || String(e))); }
          try {
            sig = await subtle.sign({ name: 'RSA-PSS', saltLength: #{salt_len} }, key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('PKey::RSA#sign_pss: sign: ' + (e.message || String(e))); }
          return new Uint8Array(sig);
        })()`
        u8_to_binstr(promise.__await__)
      end

      def verify_pss(digest_spec, signature, data, salt_length: :digest, mgf1_hash: nil)
        hash = canonical_hash(digest_spec)
        if mgf1_hash && canonical_hash(mgf1_hash) != hash
          raise PKeyError, "Web Crypto only supports MGF1 with the same hash as the message digest (#{hash})"
        end
        salt_len = pss_salt_length(salt_length, hash)
        verify_subtle({
          'name' => 'RSA-PSS',
          'hash' => hash,
          'op'   => "RSA-PSS|#{salt_len}"
        }, digest_spec, signature, data, nil, salt_len)
      end

      # ----- RSA-OAEP encrypt / decrypt ------------------------------
      # CRuby: rsa.public_encrypt(plain, padding=:pkcs1)
      # We default to OAEP (the modern recommendation). PKCS1 is also
      # supported for legacy interop. Caller selects via `padding:` arg.
      def public_encrypt(plain, padding: :oaep, hash: 'SHA-256')
        raise PKeyError, 'public key required' unless @js_public
        rsa_subtle_encrypt(plain, padding, hash)
      end

      def private_decrypt(cipher, padding: :oaep, hash: 'SHA-256')
        raise PKeyError, 'private key required' unless @js_private
        rsa_subtle_decrypt(cipher, padding, hash)
      end

      # CRuby aliases (kept for jwt / rack-session compatibility).
      def encrypt(plain, padding: :oaep, hash: 'SHA-256')
        public_encrypt(plain, padding: padding, hash: hash)
      end

      def decrypt(cipher, padding: :oaep, hash: 'SHA-256')
        private_decrypt(cipher, padding: padding, hash: hash)
      end

      private

      def pss_salt_length(spec, canonical_hash_name)
        case spec
        when :digest, nil then digest_byte_length(canonical_hash_name)
        when :max
          # Maximum per RFC 8017 §9.1.1: emLen - hLen - 2 where emLen
          # is the modulus byte length (rounded up).
          mod_bits = n.num_bits
          em_len   = (mod_bits + 7) / 8
          em_len - digest_byte_length(canonical_hash_name) - 2
        when ::Integer then spec
        else raise PKeyError, "unsupported salt_length: #{spec.inspect}"
        end
      end

      def verify_subtle(import_op, digest_spec, signature, data, op_name = nil, salt_len = nil)
        # import_op is either a String (used for both import.name and op
        # name, e.g. 'RSASSA-PKCS1-v1_5') or a Hash with 'name', 'hash',
        # 'op'. Op_name overrides on the simple-string path.
        hash = if import_op.is_a?(::Hash)
                 import_op['hash']
               else
                 canonical_hash(digest_spec)
               end
        import_name = import_op.is_a?(::Hash) ? import_op['name'] : import_op
        op = if import_op.is_a?(::Hash)
               # PSS: pass {name:'RSA-PSS', saltLength: ...}
               nil
             else
               op_name || import_op
             end
        pub = @js_public || @js_private
        sig = signature.to_s
        str = data.to_s
        is_pss = (import_name == 'RSA-PSS')
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var key, spki;
          try {
            if (#{pub}.type === 'private') {
              spki = globalThis.__nodeCrypto__.createPublicKey(#{pub}).export({ type: 'spki', format: 'der' });
            } else {
              spki = #{pub}.export({ type: 'spki', format: 'der' });
            }
            key = await subtle.importKey('spki', spki, { name: #{import_name}, hash: { name: #{hash} } }, false, ['verify']);
          } catch (e) { throw new Error('PKey verify: import failed: ' + (e.message || String(e))); }
          try {
            var op_arg = #{is_pss} ? { name: 'RSA-PSS', saltLength: #{salt_len || 0} } : #{op};
            var ok = await subtle.verify(op_arg, key, Opal.binstr_to_u8(#{sig}), Opal.binstr_to_u8(#{str}));
            return !!ok;
          } catch (e) { throw new Error('PKey verify: ' + (e.message || String(e))); }
        })()`
        promise.__await__
      end

      def rsa_subtle_encrypt(plain, padding, hash_spec)
        raise PKeyError, "PKCS1 padding via subtle is not supported by Web Crypto; use :oaep" if padding == :pkcs1
        raise PKeyError, "unsupported padding: #{padding.inspect}" unless padding == :oaep
        hash = canonical_hash(hash_spec)
        pub  = @js_public
        str  = plain.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var spki, key, ct;
          try {
            spki = #{pub}.export({ type: 'spki', format: 'der' });
            key = await subtle.importKey('spki', spki, { name: 'RSA-OAEP', hash: { name: #{hash} } }, false, ['encrypt']);
          } catch (e) { throw new Error('RSA encrypt: import: ' + (e.message || String(e))); }
          try {
            ct = await subtle.encrypt({ name: 'RSA-OAEP' }, key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('RSA encrypt: ' + (e.message || String(e))); }
          return new Uint8Array(ct);
        })()`
        u8_to_binstr(promise.__await__)
      end

      def rsa_subtle_decrypt(cipher, padding, hash_spec)
        raise PKeyError, "PKCS1 padding via subtle is not supported by Web Crypto; use :oaep" if padding == :pkcs1
        raise PKeyError, "unsupported padding: #{padding.inspect}" unless padding == :oaep
        hash = canonical_hash(hash_spec)
        priv = @js_private
        str  = cipher.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var der, key, pt;
          try {
            der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            key = await subtle.importKey('pkcs8', der, { name: 'RSA-OAEP', hash: { name: #{hash} } }, false, ['decrypt']);
          } catch (e) { throw new Error('RSA decrypt: import: ' + (e.message || String(e))); }
          try {
            pt = await subtle.decrypt({ name: 'RSA-OAEP' }, key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('RSA decrypt: ' + (e.message || String(e))); }
          return new Uint8Array(pt);
        })()`
        u8_to_binstr(promise.__await__)
      end
    end

    # ---------------------------------------------------------------
    # OpenSSL::PKey::EC — ECDSA (ES256/384/512) + ECDH key agreement
    # ---------------------------------------------------------------
    #
    # ECDSA signature format note:
    #   - CRuby OpenSSL `EC#sign` returns DER (SEQUENCE { INTEGER r, INTEGER s }).
    #   - JWT (RFC 7518 ES256/384/512) requires raw R||S concatenated.
    #   - Web Crypto subtle `sign('ECDSA', ...)` returns raw R||S.
    #
    # We default `sign` / `verify` to **DER** (CRuby compat). For JWT
    # interop, use `sign_jwt` / `verify_jwt` (raw R||S) — they are the
    # exact format JWT libraries expect.
    class EC < PKey
      CURVE_ALIASES = {
        'P-256'      => { subtle: 'P-256', size: 32 },
        'prime256v1' => { subtle: 'P-256', size: 32 },
        'P-384'      => { subtle: 'P-384', size: 48 },
        'secp384r1'  => { subtle: 'P-384', size: 48 },
        'P-521'      => { subtle: 'P-521', size: 66 },
        'secp521r1'  => { subtle: 'P-521', size: 66 }
      }.freeze

      class Group
        attr_reader :curve_name
        def initialize(curve_name)
          @curve_name = curve_name
        end
      end

      def self.new(arg = nil)
        instance = allocate
        instance.send(:setup, arg)
        instance
      end

      def self.generate(curve)
        new(curve)
      end

      def setup(arg)
        if arg.is_a?(::String) && !arg.include?('-----BEGIN')
          curve = arg
          pair = `(function() {
            var p = globalThis.__nodeCrypto__.generateKeyPairSync('ec', { namedCurve: #{curve} });
            return { priv: p.privateKey, pub: p.publicKey };
          })()`
          @js_private = `#{pair}.priv`
          @js_public  = `#{pair}.pub`
          @curve_name = curve
        else
          pem_str = arg.to_s
          loaded = `(function() {
            var pem = #{pem_str};
            try {
              var priv = globalThis.__nodeCrypto__.createPrivateKey(pem);
              var pub  = globalThis.__nodeCrypto__.createPublicKey(priv);
              return { priv: priv, pub: pub };
            } catch (e1) {
              try {
                var pub2 = globalThis.__nodeCrypto__.createPublicKey(pem);
                return { priv: null, pub: pub2 };
              } catch (e2) {
                throw new Error('PKey::EC: cannot parse key: ' + (e1.message || e2.message));
              }
            }
          })()`
          @js_private = `#{loaded}.priv`
          @js_public  = `#{loaded}.pub`
          ko = @js_public
          @curve_name = `#{ko}.asymmetricKeyDetails.namedCurve`
        end
      end

      def private_key?
        !`#{@js_private} == null`
      end

      def group
        Group.new(@curve_name)
      end

      def to_pem
        if @js_private
          priv = @js_private
          `#{priv}.export({ type: 'pkcs8', format: 'pem' })`
        else
          pub = @js_public
          `#{pub}.export({ type: 'spki', format: 'pem' })`
        end
      end

      # ----- ECDSA sign / verify -------------------------------------
      # CRuby compat default: DER signature.
      def sign(digest_spec, data)
        raw = sign_jwt(digest_spec, data).__await__
        raw_to_der(raw, curve_size)
      end

      # JWT-style raw R||S signature (returns Promise → .__await__).
      def sign_jwt(digest_spec, data)
        raise PKeyError, 'private key required' unless @js_private
        hash = canonical_hash(digest_spec)
        priv = @js_private
        str  = data.to_s
        subtle_curve = CURVE_ALIASES.fetch(@curve_name.to_s) {
          raise PKeyError, "unsupported curve: #{@curve_name}"
        }[:subtle]
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var der, key, sig;
          try {
            der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            key = await subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: #{subtle_curve} }, false, ['sign']);
          } catch (e) { throw new Error('PKey::EC#sign_jwt: import: ' + (e.message || String(e))); }
          try {
            sig = await subtle.sign({ name: 'ECDSA', hash: { name: #{hash} } }, key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('PKey::EC#sign_jwt: sign: ' + (e.message || String(e))); }
          return new Uint8Array(sig);
        })()`
        u8_to_binstr(promise.__await__)
      end

      def verify(digest_spec, signature, data)
        sig = signature.to_s
        raw = der_to_raw(sig, curve_size)
        verify_jwt(digest_spec, raw, data).__await__
      end

      def verify_jwt(digest_spec, signature, data)
        hash = canonical_hash(digest_spec)
        pub  = @js_public || @js_private
        sig  = signature.to_s
        str  = data.to_s
        subtle_curve = CURVE_ALIASES.fetch(@curve_name.to_s) {
          raise PKeyError, "unsupported curve: #{@curve_name}"
        }[:subtle]
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var spki, key;
          try {
            if (#{pub}.type === 'private') {
              spki = globalThis.__nodeCrypto__.createPublicKey(#{pub}).export({ type: 'spki', format: 'der' });
            } else {
              spki = #{pub}.export({ type: 'spki', format: 'der' });
            }
            key = await subtle.importKey('spki', spki, { name: 'ECDSA', namedCurve: #{subtle_curve} }, false, ['verify']);
          } catch (e) { throw new Error('PKey::EC#verify: import: ' + (e.message || String(e))); }
          try {
            var ok = await subtle.verify({ name: 'ECDSA', hash: { name: #{hash} } }, key, Opal.binstr_to_u8(#{sig}), Opal.binstr_to_u8(#{str}));
            return !!ok;
          } catch (e) { throw new Error('PKey::EC#verify: ' + (e.message || String(e))); }
        })()`
        promise.__await__
      end

      # ----- ECDH key agreement --------------------------------------
      # CRuby: ec_priv.dh_compute_key(ec_pub.public_key)
      # Web Crypto: subtle.deriveBits with name:'ECDH', public:peer
      def dh_compute_key(peer)
        raise PKeyError, 'private key required for dh_compute_key' unless @js_private
        peer_pub = peer.is_a?(EC) ? (peer.js_public || peer.js_private) : peer
        priv = @js_private
        subtle_curve = CURVE_ALIASES.fetch(@curve_name.to_s) {
          raise PKeyError, "unsupported curve: #{@curve_name}"
        }
        bits = subtle_curve[:size] * 8
        subtle_curve_name = subtle_curve[:subtle]
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var priv_der, peer_der, priv_key, peer_key, secret;
          try {
            priv_der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            peer_der = (#{peer_pub}.type === 'private')
              ? globalThis.__nodeCrypto__.createPublicKey(#{peer_pub}).export({ type: 'spki', format: 'der' })
              : #{peer_pub}.export({ type: 'spki', format: 'der' });
            priv_key = await subtle.importKey('pkcs8', priv_der, { name: 'ECDH', namedCurve: #{subtle_curve_name} }, false, ['deriveBits']);
            peer_key = await subtle.importKey('spki', peer_der, { name: 'ECDH', namedCurve: #{subtle_curve_name} }, false, []);
          } catch (e) { throw new Error('PKey::EC#dh_compute_key: import: ' + (e.message || String(e))); }
          try {
            secret = await subtle.deriveBits({ name: 'ECDH', public: peer_key }, priv_key, #{bits});
          } catch (e) { throw new Error('PKey::EC#dh_compute_key: derive: ' + (e.message || String(e))); }
          return new Uint8Array(secret);
        })()`
        u8_to_binstr(promise.__await__)
      end

      private

      def curve_size
        info = CURVE_ALIASES[@curve_name.to_s]
        raise PKeyError, "unknown curve size: #{@curve_name}" unless info
        info[:size]
      end

      # raw R||S → DER SEQUENCE { INTEGER r, INTEGER s }
      def raw_to_der(raw, curve_byte_size)
        bytes = raw.bytes
        raise PKeyError, "raw signature wrong size: #{bytes.size}" if bytes.size != curve_byte_size * 2
        r = trim_and_pad(bytes[0, curve_byte_size])
        s = trim_and_pad(bytes[curve_byte_size, curve_byte_size])
        inner = [0x02, r.size].pack('CC') + r.pack('C*') + [0x02, s.size].pack('CC') + s.pack('C*')
        if inner.bytesize <= 127
          [0x30, inner.bytesize].pack('CC') + inner
        elsif inner.bytesize <= 255
          [0x30, 0x81, inner.bytesize].pack('CCC') + inner
        else
          [0x30, 0x82, (inner.bytesize >> 8) & 0xff, inner.bytesize & 0xff].pack('CCCC') + inner
        end
      end

      # Strip leading 0x00 bytes; if high bit is set, prepend 0x00 so
      # ASN.1 INTEGER stays positive.
      def trim_and_pad(arr)
        a = arr.dup
        while a.size > 1 && a[0] == 0
          a.shift
        end
        a.unshift(0) if (a[0] || 0) >= 0x80
        a
      end

      # DER SEQUENCE { INTEGER r, INTEGER s } → raw R||S (curve_byte_size * 2)
      def der_to_raw(der, curve_byte_size)
        bytes = der.bytes
        i = 0
        raise PKeyError, 'invalid DER (no SEQUENCE)' unless bytes[i] == 0x30
        i += 1
        # Length: short or long form
        if bytes[i] < 0x80
          i += 1
        elsif bytes[i] == 0x81
          i += 2
        elsif bytes[i] == 0x82
          i += 3
        else
          raise PKeyError, "invalid DER length form: #{bytes[i]}"
        end
        # R INTEGER
        raise PKeyError, 'invalid DER (no INTEGER for r)' unless bytes[i] == 0x02
        r_len = bytes[i + 1]
        r = bytes[i + 2, r_len]
        i += 2 + r_len
        # S INTEGER
        raise PKeyError, 'invalid DER (no INTEGER for s)' unless bytes[i] == 0x02
        s_len = bytes[i + 1]
        s = bytes[i + 2, s_len]
        # Pad / trim each to curve_byte_size
        r = pad_or_trim(r, curve_byte_size)
        s = pad_or_trim(s, curve_byte_size)
        (r + s).pack('C*')
      end

      def pad_or_trim(arr, target)
        a = arr.dup
        a.shift while a.size > target  # drop ASN.1 sign-pad zeros
        a = [0] * (target - a.size) + a if a.size < target
        a
      end
    end

    # ---------------------------------------------------------------
    # OpenSSL::PKey::Ed25519 — EdDSA over Curve25519 (JWT alg "EdDSA")
    # ---------------------------------------------------------------
    # CRuby exposes EdDSA as `OpenSSL::PKey.generate_key('ED25519')`
    # since Ruby 3.0; we wrap subtle 'Ed25519'.
    class Ed25519 < PKey
      def self.generate
        instance = allocate
        instance.send(:setup_generate)
        instance
      end

      def self.new(pem = nil)
        instance = allocate
        instance.send(:setup_load, pem) if pem
        instance.send(:setup_generate) if pem.nil?
        instance
      end

      def setup_generate
        pair = `(function() {
          var p = globalThis.__nodeCrypto__.generateKeyPairSync('ed25519');
          return { priv: p.privateKey, pub: p.publicKey };
        })()`
        @js_private = `#{pair}.priv`
        @js_public  = `#{pair}.pub`
      end

      def setup_load(pem)
        pem_str = pem.to_s
        loaded = `(function() {
          try {
            var priv = globalThis.__nodeCrypto__.createPrivateKey(#{pem_str});
            var pub  = globalThis.__nodeCrypto__.createPublicKey(priv);
            return { priv: priv, pub: pub };
          } catch (e1) {
            try {
              var pub2 = globalThis.__nodeCrypto__.createPublicKey(#{pem_str});
              return { priv: null, pub: pub2 };
            } catch (e2) {
              throw new Error('PKey::Ed25519: cannot parse: ' + (e1.message || e2.message));
            }
          }
        })()`
        @js_private = `#{loaded}.priv`
        @js_public  = `#{loaded}.pub`
      end

      def private?
        !`#{@js_private} == null`
      end

      def public_key
        new_pub = self.class.allocate
        new_pub.instance_variable_set(:@js_public, @js_public)
        new_pub.instance_variable_set(:@js_private, nil)
        new_pub
      end

      def to_pem
        ko = @js_private || @js_public
        type = @js_private ? 'pkcs8' : 'spki'
        `#{ko}.export({ type: #{type}, format: 'pem' })`
      end

      # Ed25519 sign — JWT EdDSA. No digest argument (Ed25519 does
      # SHA-512 internally). Caller passes nil for the digest arg or
      # a string that's ignored.
      def sign(_digest_or_nil, data)
        raise PKeyError, 'private key required' unless @js_private
        priv = @js_private
        str  = data.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var der, key, sig;
          try {
            der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            key = await subtle.importKey('pkcs8', der, { name: 'Ed25519' }, false, ['sign']);
          } catch (e) { throw new Error('Ed25519#sign: import: ' + (e.message || String(e))); }
          try {
            sig = await subtle.sign({ name: 'Ed25519' }, key, Opal.binstr_to_u8(#{str}));
          } catch (e) { throw new Error('Ed25519#sign: ' + (e.message || String(e))); }
          return new Uint8Array(sig);
        })()`
        u8_to_binstr(promise.__await__)
      end

      def verify(_digest_or_nil, signature, data)
        pub = @js_public || @js_private
        sig = signature.to_s
        str = data.to_s
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var spki, key;
          try {
            spki = (#{pub}.type === 'private')
              ? globalThis.__nodeCrypto__.createPublicKey(#{pub}).export({ type: 'spki', format: 'der' })
              : #{pub}.export({ type: 'spki', format: 'der' });
            key = await subtle.importKey('spki', spki, { name: 'Ed25519' }, false, ['verify']);
          } catch (e) { throw new Error('Ed25519#verify: import: ' + (e.message || String(e))); }
          try {
            var ok = await subtle.verify({ name: 'Ed25519' }, key, Opal.binstr_to_u8(#{sig}), Opal.binstr_to_u8(#{str}));
            return !!ok;
          } catch (e) { throw new Error('Ed25519#verify: ' + (e.message || String(e))); }
        })()`
        promise.__await__
      end
    end

    # ---------------------------------------------------------------
    # OpenSSL::PKey::X25519 — Curve25519 ECDH key agreement
    # ---------------------------------------------------------------
    class X25519 < PKey
      def self.generate
        instance = allocate
        instance.send(:setup_generate)
        instance
      end

      def self.new(pem = nil)
        instance = allocate
        instance.send(:setup_load, pem) if pem
        instance.send(:setup_generate) if pem.nil?
        instance
      end

      def setup_generate
        pair = `(function() {
          var p = globalThis.__nodeCrypto__.generateKeyPairSync('x25519');
          return { priv: p.privateKey, pub: p.publicKey };
        })()`
        @js_private = `#{pair}.priv`
        @js_public  = `#{pair}.pub`
      end

      def setup_load(pem)
        pem_str = pem.to_s
        loaded = `(function() {
          try {
            var priv = globalThis.__nodeCrypto__.createPrivateKey(#{pem_str});
            var pub  = globalThis.__nodeCrypto__.createPublicKey(priv);
            return { priv: priv, pub: pub };
          } catch (e1) {
            try {
              var pub2 = globalThis.__nodeCrypto__.createPublicKey(#{pem_str});
              return { priv: null, pub: pub2 };
            } catch (e2) {
              throw new Error('PKey::X25519: cannot parse: ' + (e1.message || e2.message));
            }
          }
        })()`
        @js_private = `#{loaded}.priv`
        @js_public  = `#{loaded}.pub`
      end

      def private?
        !`#{@js_private} == null`
      end

      def public_key
        new_pub = self.class.allocate
        new_pub.instance_variable_set(:@js_public, @js_public)
        new_pub.instance_variable_set(:@js_private, nil)
        new_pub
      end

      def to_pem
        ko = @js_private || @js_public
        type = @js_private ? 'pkcs8' : 'spki'
        `#{ko}.export({ type: #{type}, format: 'pem' })`
      end

      def dh_compute_key(peer)
        raise PKeyError, 'private key required for dh_compute_key' unless @js_private
        peer_pub = peer.is_a?(X25519) ? (peer.js_public || peer.js_private) : peer
        priv = @js_private
        promise = `(async function() {
          var subtle = globalThis.crypto.subtle;
          var priv_der, peer_der, priv_key, peer_key, secret;
          try {
            priv_der = #{priv}.export({ type: 'pkcs8', format: 'der' });
            peer_der = (#{peer_pub}.type === 'private')
              ? globalThis.__nodeCrypto__.createPublicKey(#{peer_pub}).export({ type: 'spki', format: 'der' })
              : #{peer_pub}.export({ type: 'spki', format: 'der' });
            priv_key = await subtle.importKey('pkcs8', priv_der, { name: 'X25519' }, false, ['deriveBits']);
            peer_key = await subtle.importKey('spki', peer_der, { name: 'X25519' }, false, []);
          } catch (e) { throw new Error('X25519#dh_compute_key: import: ' + (e.message || String(e))); }
          try {
            secret = await subtle.deriveBits({ name: 'X25519', public: peer_key }, priv_key, 256);
          } catch (e) { throw new Error('X25519#dh_compute_key: derive: ' + (e.message || String(e))); }
          return new Uint8Array(secret);
        })()`
        u8_to_binstr(promise.__await__)
      end
    end
  end

  # =================================================================
  # OpenSSL::KDF
  # =================================================================
  module KDF
    def self.pbkdf2_hmac(password, salt:, iterations:, length:, hash:)
      pwd  = password.to_s
      slt  = salt.to_s
      iter = iterations.to_i
      len  = length.to_i
      algo = OpenSSL.normalize_digest(hash)
      hex = `globalThis.__nodeCrypto__.pbkdf2Sync(Buffer.from(#{pwd}, 'utf8'), Buffer.from(#{slt}, 'utf8'), #{iter}, #{len}, #{algo}).toString('hex')`
      [hex].pack('H*')
    end

    def self.hkdf(ikm, salt:, info:, length:, hash:)
      i  = ikm.to_s
      s  = salt.to_s
      f  = info.to_s
      n  = length.to_i
      algo = OpenSSL.normalize_digest(hash)
      hex = `(function() {
        var buf = globalThis.__nodeCrypto__.hkdfSync(#{algo}, Buffer.from(#{i}, 'utf8'), Buffer.from(#{s}, 'utf8'), Buffer.from(#{f}, 'utf8'), #{n});
        return Buffer.from(buf).toString('hex');
      })()`
      [hex].pack('H*')
    end
  end

  # =================================================================
  # OpenSSL::Random — augment SecureRandom-compatible bytes.
  # =================================================================
  module Random
    def self.random_bytes(len)
      hex = `globalThis.__nodeCrypto__.randomBytes(#{len.to_i}).toString('hex')`
      [hex].pack('H*')
    end
  end
end
