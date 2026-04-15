# backtick_javascript: true
# Runtime patches to extend Opal's corelib with methods required by
# real-world gems (Sinatra, Rack, Mustermann, ...) that are missing
# from upstream opal 1.8.3.rc1. Each patch is kept strictly additive:
# it only installs a method if the method does not already exist.
#
# We prefer to patch Opal here (in the adapter layer) rather than
# modifying the vendored gems, so that vendored code keeps the same
# shape as its upstream counterparts. If a patch here turns out to
# fix something upstream Opal is missing, it should be turned into
# a PR against github.com/opal/opal.

# -----------------------------------------------------------------
# Module#deprecate_constant
# -----------------------------------------------------------------
# CRuby 2.6+ ships `Module#deprecate_constant(*names)` which marks the
# listed constants so that accessing them prints a deprecation warning.
# Opal 1.8.3.rc1 does not implement this, so any gem that calls
# `deprecate_constant :FOO` at module-load time aborts with a
# method_missing error. Real-world examples that hit this in Phase 2:
#   * rack/multipart/parser.rb -> deprecate_constant :CHARSET
#
# Ruby's behaviour is "warn on read, still return the value", which we
# approximate here as a no-op (Opal has no const-access hook to warn
# from, and a warning-only behaviour does not affect program output).
class Module
  unless private_method_defined?(:deprecate_constant) || method_defined?(:deprecate_constant)
    def deprecate_constant(*_names)
      self
    end
    private :deprecate_constant
  end
end

# -----------------------------------------------------------------
# Encoding::* constants that Opal corelib does not register
# -----------------------------------------------------------------
# Opal ships a handful of encodings in opal/corelib/string/encoding.rb
# (UTF-8, UTF-16{LE,BE}, UTF-32{LE,BE}, ASCII-8BIT, ISO-8859-1, US-ASCII).
# Real-world gems reference many more legacy encodings that Opal never
# declares. When such a constant appears at class-load time (e.g. in a
# constant hash literal inside rack/multipart/parser.rb), Opal raises
# `NameError: uninitialized constant Encoding::FOO` and aborts the
# whole require chain.
#
# Real transcoding is out of scope for Phase 2 — Workers do not need to
# convert ISO-2022-JP for hello-world. We install each missing constant
# as an alias of an encoding Opal already ships so that the constant
# reference succeeds. If a gem actually calls .encode onto one of these
# Opal will raise a clear error at the call site, which is what we want.
# -----------------------------------------------------------------
# Module#const_defined? / Module#const_get — qualified name support
# -----------------------------------------------------------------
# CRuby's `Module#const_defined?` and `Module#const_get` both accept
# "Foo::Bar::Baz" style qualified names. Opal 1.8.3.rc1 supports
# qualified names in `const_get` but NOT in `const_defined?`, so any
# call like `Object.const_defined?('Mustermann::AST::Node::Root')`
# returns false (or raises NameError) even when the constant exists,
# and Mustermann's `Node[:root]` factory falls through to `nil`.
#
# Patch: split qualified names in `const_defined?` and walk the chain
# exactly like `const_get` does.
class Module
  unless instance_method(:const_defined?).source_location.nil?
    # pass — we monkey-patch regardless
  end

  alias_method :__homurabi_const_defined_simple, :const_defined?

  def const_defined?(name, inherit = true)
    name_str = name.to_s
    if name_str.include?('::')
      parts = name_str.split('::')
      parts.shift if parts.first.empty?  # leading "::Foo::Bar"
      current = self
      parts.each do |part|
        return false unless current.__homurabi_const_defined_simple(part, inherit)
        current = current.const_get(part, inherit)
        return false unless current.is_a?(Module)
      end
      true
    else
      __homurabi_const_defined_simple(name, inherit)
    end
  end
end

# -----------------------------------------------------------------
# Global defaults that Opal does not initialise
# -----------------------------------------------------------------
# CRuby sets `$0` to the program name from argv[0]. Opal leaves it
# as nil, which breaks gems that call `File.expand_path($0)` at class-
# body time (sinatra/main.rb: `proc { File.expand_path($0) }`).
# Install a harmless default string.
$0 ||= '(homurabi)'
$PROGRAM_NAME ||= $0

# (Previously this file force-set APP_ENV/RACK_ENV to 'production' to
# keep Rack::ShowExceptions out of the way — its ERB renderer uses
# `binding.eval` which lands on `new Function($code)`, forbidden on
# Workers. The real fix is now in `vendor/rack/show_exceptions.rb`
# where `#pretty` builds the HTML directly, so we no longer need to
# hide development mode. Users who want production settings should
# set `APP_ENV=production` themselves, same as on any Rack server.)

# Load Opal's stdlib Forwardable BEFORE patching it, so our overrides
# are applied last and are not clobbered when a vendored gem requires
# 'forwardable' transitively.
require 'forwardable'

# -----------------------------------------------------------------
# (removed) Debug method_missing logger — was used while iterating
# through Phase 2 init-time issues. Permanent fix for the root cause
# (Opal `@prototype` collision) landed in vendor/opal-gem/. Keeping
# method_missing unpatched restores the fast path for real requests.
# -----------------------------------------------------------------

# -----------------------------------------------------------------
# Forwardable#def_instance_delegator — support for expression accessors
# -----------------------------------------------------------------
# CRuby's Forwardable evaluates the `accessor` argument as a Ruby
# expression when it is neither an ivar (`@foo`) nor a plain method
# name — so `def_delegator 'self.class', :foo` delegates to the current
# class's #foo method. Opal's simplified Forwardable (stdlib/forwardable.rb)
# just treats the accessor literally and calls `__send__('self.class')`,
# which raises method_missing.
#
# Mustermann's AST::Pattern relies on this exact CRuby behaviour:
#
#   instance_delegate %i[parser compiler ...] => 'self.class'
#
# so without this patch the first Mustermann::Pattern#compile call from
# Sinatra::Base#route aborts the whole require chain. The fix below
# re-implements def_instance_delegator / def_single_delegator so that
# non-ivar accessors that look like Ruby expressions go through
# `instance_eval` / `class_eval` instead of `__send__`.
# homurabi patch: Cloudflare Workers disallows `new Function($code)` /
# `eval($code)` (Workers' "Code generation from strings disallowed" rule).
# Opal's `instance_eval(String)` compiles to a `new Function($code)` call,
# so any Forwardable delegation with an *expression* accessor (Mustermann's
# `instance_delegate %i[parser compiler] => 'self.class'` is the real-world
# trigger) crashes on Workers at first dispatch.
#
# The helper below walks a small subset of dot-separated accessor
# expressions — `self`, `self.class`, `@ivar`, `@ivar.method`, plain
# `method_name`, `method_name.other_method` — without going through
# `instance_eval`. Mustermann (and the Ruby stdlib itself) only uses
# identifiers from that subset, so we never need the full Ruby parser.
module ForwardableAccessor
  module_function

  def resolve(instance, expr)
    expr = expr.to_s
    current = instance
    expr.split('.').each do |part|
      current = if part == 'self'
                  instance
                elsif part.start_with?('@')
                  instance.instance_variable_get(part)
                else
                  current.__send__(part)
                end
    end
    current
  end
end

module Forwardable
  remove_method :def_instance_delegator if method_defined?(:def_instance_delegator)

  def def_instance_delegator(accessor, method, ali = method)
    accessor_str = accessor.to_s
    if accessor_str.start_with?('@') && !accessor_str.include?('.')
      define_method ali do |*args, &block|
        instance_variable_get(accessor_str).__send__(method, *args, &block)
      end
    elsif accessor_str =~ /\A[A-Za-z_]\w*\z/
      # Plain identifier (method name) — call via __send__ as before.
      define_method ali do |*args, &block|
        __send__(accessor_str).__send__(method, *args, &block)
      end
    else
      # Dot-path expression like 'self.class'. Resolve without eval.
      define_method ali do |*args, &block|
        ForwardableAccessor.resolve(self, accessor_str).__send__(method, *args, &block)
      end
    end
  end
end

module SingleForwardable
  remove_method :def_single_delegator if method_defined?(:def_single_delegator)

  def def_single_delegator(accessor, method, ali = method)
    accessor_str = accessor.to_s
    if accessor_str.start_with?('@') && !accessor_str.include?('.')
      define_singleton_method ali do |*args, &block|
        instance_variable_get(accessor_str).__send__(method, *args, &block)
      end
    elsif accessor_str =~ /\A[A-Za-z_]\w*\z/
      define_singleton_method ali do |*args, &block|
        __send__(accessor_str).__send__(method, *args, &block)
      end
    else
      define_singleton_method ali do |*args, &block|
        ForwardableAccessor.resolve(self, accessor_str).__send__(method, *args, &block)
      end
    end
  end
end

# -----------------------------------------------------------------
# URI::DEFAULT_PARSER — CGI-backed stand-in
# -----------------------------------------------------------------
# Opal ships a tiny `uri.rb` that does not define RFC2396_PARSER or
# DEFAULT_PARSER. Multiple gems reference URI::DEFAULT_PARSER at
# method default-value time (eager on first call) or at constant
# lookup time:
#   - rack/utils.rb                             (already handled in vendor patch)
#   - mustermann/ast/translator.rb line 121:    def escape(char, parser: URI::DEFAULT_PARSER, ...)
#   - mustermann/pattern.rb line 12:            @@uri ||= URI::Parser.new
#
# We install a module-shaped URI::DEFAULT_PARSER that wraps CGI so
# that gems that only call escape / unescape / regexp[:UNSAFE] on it
# continue to work.
require 'uri' rescue nil
require 'cgi'

module ::URI
  unless const_defined?(:DEFAULT_PARSER)
    DEFAULT_PARSER = Module.new do
      UNSAFE = Regexp.compile('[^\-_.!~*\'()a-zA-Z0-9;/?:@&=+$,\[\]]').freeze

      def self.regexp
        { UNSAFE: UNSAFE }
      end

      def self.escape(s, unsafe = UNSAFE)
        CGI.escape(s.to_s)
      end

      def self.unescape(s)
        CGI.unescape(s.to_s)
      end
    end
  end

  # CRuby's URI.decode_www_form_component / encode_www_form_component are used
  # by Rack::Utils#unescape / Rack::Utils#escape. Opal's `uri` stdlib omits
  # them. Back them with CGI so that Rack's query-string parser works for
  # any request with a body / query (Sinatra's `request.body.read` path
  # eventually walks through this code).
  unless respond_to?(:decode_www_form_component)
    def self.decode_www_form_component(str, _enc = nil)
      CGI.unescape(str.to_s)
    end
  end

  unless respond_to?(:encode_www_form_component)
    def self.encode_www_form_component(str, _enc = nil)
      CGI.escape(str.to_s)
    end
  end

  unless const_defined?(:RFC2396_PARSER)
    RFC2396_PARSER = DEFAULT_PARSER
  end

  unless const_defined?(:Parser)
    # Some gems instantiate URI::Parser.new directly. Return the
    # singleton module which has the same surface area.
    class Parser
      def self.new(*)
        ::URI::DEFAULT_PARSER
      end
    end
  end

  # Rack::Protection::JsonCsrf#has_vector? does `rescue URI::InvalidURIError`,
  # so the constant needs to exist even if the referrer is actually valid.
  unless const_defined?(:InvalidURIError)
    class InvalidURIError < StandardError; end
  end

  unless const_defined?(:Error)
    class Error < StandardError; end
  end

  # Opal's stdlib does not implement URI.parse. Rack::Protection calls
  # `URI.parse(env['HTTP_REFERER']).host`. A tiny JS-URL-backed parser is
  # enough to cover that and any equivalent `host`-only usage.
  class Generic
    attr_reader :host, :scheme, :port, :path, :query, :fragment

    def initialize(host:, scheme:, port:, path:, query:, fragment:)
      @host = host
      @scheme = scheme
      @port = port
      @path = path
      @query = query
      @fragment = fragment
    end
  end

  def self.parse(str)
    s = str.to_s
    return Generic.new(host: nil, scheme: nil, port: nil, path: '', query: nil, fragment: nil) if s.empty?

    js_url = `
      (function() {
        try { return new URL(#{s}); }
        catch (e) {
          try { return new URL(#{s}, "http://__homurabi.invalid/"); }
          catch (e2) { return null; }
        }
      })()
    `
    raise ::URI::InvalidURIError, "bad URI(is not URI?): #{s}" if `#{js_url} == null`

    host     = `#{js_url}.host` || ''
    host     = nil if host == '' || host.include?('__homurabi.invalid')
    scheme   = `#{js_url}.protocol` || ''
    scheme   = scheme.sub(/:$/, '')
    scheme   = nil if scheme == ''
    port_raw = `#{js_url}.port` || ''
    port     = port_raw == '' ? nil : port_raw.to_i
    path     = `#{js_url}.pathname` || ''
    query    = `#{js_url}.search` || ''
    query    = query.sub(/^\?/, '')
    query    = nil if query == ''
    frag     = `#{js_url}.hash` || ''
    frag     = frag.sub(/^#/, '')
    frag     = nil if frag == ''

    Generic.new(host: host, scheme: scheme, port: port, path: path, query: query, fragment: frag)
  end
end

# -----------------------------------------------------------------
# IO.read / IO.binread / File.read / File.binread — Workers have no FS
# -----------------------------------------------------------------
# Opal does not implement IO.read / File.read. On Cloudflare Workers
# there is no writable filesystem anyway, so any code that tries to
# read a local file will fail. Gems that *optionally* read a file
# (Sinatra's inline_templates= for example) expect an Errno::ENOENT
# and rescue it silently; plain method_missing breaks that rescue.
#
# Install Errno::ENOENT-raising stubs so callers that rescue the
# standard not-found exception take the silent path. Callers that
# do not rescue get a clear, specific error instead of method_missing.
module ::Kernel
  module_function
end

# -----------------------------------------------------------------
# SecureRandom — Web Crypto API with graceful fallback
# -----------------------------------------------------------------
# Cloudflare Workers forbids async I/O AND random-value generation at
# module-load time (global scope). Sinatra eagerly generates a session
# secret at class-body time via SecureRandom.hex(64), which crashes
# with "Disallowed operation called within global scope" on Workers.
#
# We provide a SecureRandom implementation that:
#   1. Tries `crypto.getRandomValues` via Web Crypto (works inside fetch
#      handlers on Workers and everywhere on Node/browsers).
#   2. Catches any failure (including the Workers global-scope
#      restriction) and falls back to a deterministic all-zero string.
#
# Sinatra's session_secret therefore becomes "000…0" for the duration
# of the isolate lifetime when no request is in flight. That is the
# same strength CRuby Sinatra gives you when SecureRandom is unavailable
# (it falls back to `Kernel.rand`), so we are not reducing security
# beyond upstream's own fallback path.
# Ensure our Digest/Zlib/Tempfile/Tilt stubs from vendor/ are available
# everywhere, even when a gem references `Digest::SHA1` at class body
# time without explicitly `require 'digest'`-ing first.
require 'digest'
require 'digest/sha2'
require 'zlib'
require 'tempfile'
require 'tilt'

module ::SecureRandom
  def self.random_bytes(n = 16)
    n = n.to_i
    n = 16 if n <= 0
    hex_string = hex(n)
    result = +''
    i = 0
    while i < hex_string.length
      result << hex_string[i, 2].to_i(16).chr
      i += 2
    end
    result
  rescue StandardError
    ("\0" * n)
  end

  def self.hex(n = 16)
    n = n.to_i
    n = 16 if n <= 0
    `
      try {
        if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
          var bytes = new Uint8Array(n);
          crypto.getRandomValues(bytes);
          var out = '';
          for (var i = 0; i < bytes.length; i++) {
            var h = bytes[i].toString(16);
            if (h.length < 2) h = '0' + h;
            out += h;
          }
          return out;
        }
      } catch (e) {
        // Workers blocks getRandomValues at global scope; fall through.
      }
      return '0'.repeat(n * 2);
    `
  end

  def self.uuid
    h = hex(16)
    "#{h[0, 8]}-#{h[8, 4]}-4#{h[13, 3]}-#{h[16, 4]}-#{h[20, 12]}"
  end

  def self.base64(n = 16)
    require 'base64'
    Base64.strict_encode64(random_bytes(n))
  rescue StandardError
    '0' * n
  end

  def self.urlsafe_base64(n = 16, padding = false)
    s = base64(n).tr('+/', '-_')
    padding ? s : s.delete('=')
  end

  def self.random_number(n = 0)
    # Not used at class-init time; real implementations welcome.
    0
  end
end

class ::IO
  def self.read(*args)
    raise ::Errno::ENOENT, args.first.to_s
  end

  def self.binread(*args)
    raise ::Errno::ENOENT, args.first.to_s
  end
end

# File inherits from IO in CRuby; in Opal File is its own class.
# Install the same stubs on File defensively.
begin
  file_class = ::File
  unless file_class.respond_to?(:read) && !file_class.method(:read).source_location.nil?
    def file_class.read(*args)
      raise ::Errno::ENOENT, args.first.to_s
    end
    def file_class.binread(*args)
      raise ::Errno::ENOENT, args.first.to_s
    end
  end
  unless file_class.respond_to?(:fnmatch)
    def file_class.fnmatch(pattern, path, *)
      # Very small fnmatch: supports `*` and `?` only, good enough for
      # Sinatra's template extension matching.
      regex = '\A'
      i = 0
      p = pattern.to_s
      while i < p.length
        c = p[i]
        case c
        when '*' then regex += '.*'
        when '?' then regex += '.'
        when '.', '(', ')', '[', ']', '+', '^', '$' then regex += "\\#{c}"
        else regex += c
        end
        i += 1
      end
      regex += '\z'
      !!(path.to_s =~ Regexp.new(regex))
    end
    def file_class.fnmatch?(pattern, path, *)
      fnmatch(pattern, path)
    end
  end
rescue NameError
  # File not available at this load point — ignore.
end

[
  :ISO_2022_JP,
  :SHIFT_JIS, :Shift_JIS, :WINDOWS_31J, :CP932, :SJIS,
  :EUC_JP, :EUC_KR, :EUC_CN, :EUC_TW,
  :BIG5, :GB18030, :GBK, :GB2312,
  :WINDOWS_1250, :WINDOWS_1251, :WINDOWS_1252, :WINDOWS_1253,
  :WINDOWS_1254, :WINDOWS_1255, :WINDOWS_1256, :WINDOWS_1257, :WINDOWS_1258,
  :KOI8_R, :KOI8_U,
  :ISO_8859_2, :ISO_8859_3, :ISO_8859_4, :ISO_8859_5,
  :ISO_8859_6, :ISO_8859_7, :ISO_8859_8, :ISO_8859_9,
  :ISO_8859_10, :ISO_8859_11, :ISO_8859_13, :ISO_8859_14,
  :ISO_8859_15, :ISO_8859_16,
  :MACROMAN
].each do |name|
  unless Encoding.const_defined?(name)
    Encoding.const_set(name, Encoding::ASCII_8BIT)
  end
end
