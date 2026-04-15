# backtick_javascript: true
# Cloudflare Workers runtime adapter for Opal.
#
# Opal's default `puts` is wired through nodejs.rb's `$stdout`, whose
# `write_proc` calls `process.stdout.write`. On Cloudflare Workers the
# `process.stdout` shim provided by `nodejs_compat` is a Socket that
# is closed inside the isolate, so any `puts` aborts with
# `Uncaught Error: Socket is closed`.
#
# This adapter replaces `$stdout` and `$stderr` with IO-shaped objects
# that delegate to V8's `console.log` / `console.error`. With this
# adapter loaded by Opal at compile time (`opal -I lib -r cloudflare_workers`),
# user Ruby code stays pure: `puts "hi"` Just Works on Workers.
#
# Note: Opal Strings are immutable (they map to JS Strings), so this file
# uses reassignment (`@buffer = @buffer + str`) instead of `<<` mutation.

class CloudflareWorkersIO
  def initialize(channel)
    @channel = channel  # 'log' or 'error'
    @buffer = ''
  end

  # Append data to the line buffer and flush completed lines to console.*
  def write(*args)
    written = 0
    args.each do |arg|
      str = arg.to_s
      @buffer = @buffer + str
      written += str.length
    end
    flush_lines
    written
  end

  # Mirror Kernel#puts semantics: each arg becomes one line; bare
  # newlines are not duplicated; an empty call prints a blank line.
  def puts(*args)
    if args.empty?
      emit('')
      return nil
    end
    args.each do |arg|
      if arg.is_a?(Array)
        puts(*arg)
        next
      end
      line = arg.to_s
      @buffer = @buffer + (line.end_with?("\n") ? line : line + "\n")
    end
    flush_lines
    nil
  end

  def print(*args)
    args.each { |a| @buffer = @buffer + a.to_s }
    flush_lines
    nil
  end

  def flush
    return self if @buffer.empty?
    emit(@buffer)
    @buffer = ''
    self
  end

  def sync; true; end
  def sync=(_); end
  def tty?; false; end
  def isatty; false; end
  def closed?; false; end

  private

  def flush_lines
    while (idx = @buffer.index("\n"))
      line = @buffer[0...idx]
      @buffer = @buffer[(idx + 1)..-1] || ''
      emit(line)
    end
  end

  # Bridge to V8's console.* via Opal's backtick JS escape.
  def emit(line)
    channel = @channel
    text = line
    `globalThis.console[#{channel}](#{text})`
  end
end

$stdout = CloudflareWorkersIO.new('log')
$stderr = CloudflareWorkersIO.new('error')
Object.const_set(:STDOUT, $stdout) unless Object.const_defined?(:STDOUT) && STDOUT.is_a?(CloudflareWorkersIO)
Object.const_set(:STDERR, $stderr) unless Object.const_defined?(:STDERR) && STDERR.is_a?(CloudflareWorkersIO)
