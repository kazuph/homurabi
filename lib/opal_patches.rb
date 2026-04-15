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

# Load Opal's stdlib Forwardable BEFORE patching it, so our overrides
# are applied last and are not clobbered when a vendored gem requires
# 'forwardable' transitively.
require 'forwardable'

# -----------------------------------------------------------------
# Debug: log the first 20 method_missing calls (Phase 2 investigation)
# -----------------------------------------------------------------
# Temporarily enabled while iterating through Opal/Sinatra/Rack/Mustermann
# init-time issues so the offending method name is visible in node output.
# Remove once Phase 2 stabilises.
module Kernel
  HOMURABI_MM_LOG_MAX = 40
  @@homurabi_mm_log_count = 0

  alias_method :__homurabi_original_method_missing, :method_missing

  def method_missing(name, *args, &block)
    if @@homurabi_mm_log_count < HOMURABI_MM_LOG_MAX
      @@homurabi_mm_log_count += 1
      klass_name = `(#{self}.$$name) || (#{self}.$$class && #{self}.$$class.$$name) || typeof #{self}`
      recv_inspect = begin
        self.inspect[0, 80]
      rescue
        '<inspect-failed>'
      end
      `console.error('[HOMURABI_MM ' + #{@@homurabi_mm_log_count} + '] ' + #{name.to_s} + ' on ' + klass_name + ' recv=' + #{recv_inspect})`
    end
    __homurabi_original_method_missing(name, *args, &block)
  end
end

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
module Forwardable
  remove_method :def_instance_delegator if method_defined?(:def_instance_delegator)

  def def_instance_delegator(accessor, method, ali = method)
    accessor_str = accessor.to_s
    if accessor_str.start_with?('@')
      define_method ali do |*args, &block|
        instance_variable_get(accessor_str).__send__(method, *args, &block)
      end
    elsif accessor_str =~ /\A[A-Za-z_]\w*\z/
      # Plain identifier (method name) — call via __send__ as before.
      define_method ali do |*args, &block|
        __send__(accessor_str).__send__(method, *args, &block)
      end
    else
      # Expression like 'self.class'. Evaluate on the instance.
      define_method ali do |*args, &block|
        instance_eval(accessor_str).__send__(method, *args, &block)
      end
    end
  end
end

module SingleForwardable
  remove_method :def_single_delegator if method_defined?(:def_single_delegator)

  def def_single_delegator(accessor, method, ali = method)
    accessor_str = accessor.to_s
    if accessor_str.start_with?('@')
      define_singleton_method ali do |*args, &block|
        instance_variable_get(accessor_str).__send__(method, *args, &block)
      end
    elsif accessor_str =~ /\A[A-Za-z_]\w*\z/
      define_singleton_method ali do |*args, &block|
        __send__(accessor_str).__send__(method, *args, &block)
      end
    else
      define_singleton_method ali do |*args, &block|
        instance_eval(accessor_str).__send__(method, *args, &block)
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
