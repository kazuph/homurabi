# backtick_javascript: true

class ::Random
  module self::Formatter
    def hex(count = nil)
      count = ::Random._verify_count(count)
      %x{
        var bytes = #{bytes(count)};
        var out = "";
        for (var i = 0; i < #{count}; i++) {
          out += bytes.charCodeAt(i).toString(16).padStart(2, '0');
        }
        return #{`out`.encode('US-ASCII')};
      }
    end

    def random_bytes(count = nil)
      bytes(count)
    end

    def base64(count = nil)
      ::Base64.strict_encode64(random_bytes(count)).encode('US-ASCII')
    end

    def urlsafe_base64(count = nil, padding = false)
      ::Base64.urlsafe_encode64(random_bytes(count), padding).encode('US-ASCII')
    end

    def uuid
      str = hex(16).split('')
      str[12] = '4'
      str[16] = `(parseInt(#{str[16]}, 16) & 3 | 8).toString(16)`
      str = [str[0...8], str[8...12], str[12...16], str[16...20], str[20...32]]
      str = str.map(&:join)
      str.join('-')
    end

    # Implemented in terms of `#bytes` for SecureRandom, but Random overrides this
    # method to implement `#bytes` in terms of `#random_float`. Not part of standard
    # Ruby interface - use random_number for portability.
    def random_float
      bs = bytes(4)
      num = 0
      4.times do |i|
        num <<= 8
        num |= bs[i].ord
      end
      # `Integer / Integer` is integer division on both CRuby and Opal,
      # so the previous `num.abs / 0x7fffffff` collapsed to 0 (or rarely 1)
      # and turned `SecureRandom.random_number(N)` into a constant 0.
      # Force the divisor to a Float so we get a true [0, 1) float, then
      # the caller's `Math.floor(randomFloat() * N)` produces a real
      # uniform distribution.
      num.abs.to_f / 0x7fffffff
    end

    # Note: this implementation used to be a single `%x{...}` JS block
    # with `function randomFloat() { return #{random_float}; }` at the
    # top, which on Opal compiles to a JS function that captures the
    # *first* result of `self.$random_float()` and never reruns the Ruby
    # interpolation — leaving `SecureRandom.random_number(N)` pinned to
    # whatever value the first call returned (often 0 because of the
    # earlier integer-division bug in `random_float`). Implementing the
    # branching in Ruby calls `random_float` properly on every invocation.
    def random_number(limit = undefined)
      return random_float if `#{limit} == null`

      if `#{limit}.$$is_range`
        min = limit.begin
        max = limit.end
        return nil if `#{min} === nil || #{max} === nil`

        length = max - min
        return nil if length < 0
        return min if length == 0

        if max.is_a?(::Integer) && min.is_a?(::Integer) && !limit.exclude_end?
          length += 1
        end

        return (random_float * length).floor + min
      end

      if `#{limit}.$$is_number`
        ::Kernel.raise ::ArgumentError, "invalid argument - #{limit}" if limit <= 0
        return (random_float * limit).floor if `#{limit} % 1 === 0`

        return random_float * limit
      end

      limit = ::Opal.coerce_to!(limit, ::Integer, :to_int)
      ::Kernel.raise ::ArgumentError, "invalid argument - #{limit}" if limit <= 0
      (random_float * limit).floor
    end

    def alphanumeric(count = nil)
      count = Random._verify_count(count)
      map = ['0'..'9', 'a'..'z', 'A'..'Z'].map(&:to_a).flatten
      ::Array.new(count) do |i|
        map[random_number(map.length)]
      end.join
    end
  end

  include ::Random::Formatter
  extend ::Random::Formatter
end
