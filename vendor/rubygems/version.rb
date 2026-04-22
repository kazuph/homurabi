# frozen_string_literal: true
#
# homura Opal stub for Gem::Version.
#
# Upstream Sinatra 4.x uses `Gem::Version.new(RUBY_VERSION) >=
# Gem::Version.new("3.0")` to conditionally activate the `except`
# override on IndifferentHash. Opal does not bundle RubyGems, so we
# provide a tiny comparator that parses dotted versions as Integer
# arrays (sufficient for the Sinatra use-case).

module Gem
  class Version
    include Comparable

    attr_reader :parts

    def initialize(str)
      @parts = str.to_s.split('.').map { |s| s.to_i rescue 0 }
    end

    def <=>(other)
      return nil unless other.is_a?(Version)
      i = 0
      max = [parts.size, other.parts.size].max
      while i < max
        a = parts[i] || 0
        b = other.parts[i] || 0
        cmp = a <=> b
        return cmp unless cmp == 0
        i += 1
      end
      0
    end
  end
end
