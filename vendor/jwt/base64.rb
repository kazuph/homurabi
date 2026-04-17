# frozen_string_literal: true
#
# homurabi patch: vendored from ruby-jwt v2.9.3 base64.rb.
# `::Base64.urlsafe_encode64` in Opal's base64 corelib does not accept the
# `padding:` keyword argument from CRuby 2.5+, so we strip padding manually
# with `.delete('=')`. Everything else matches upstream byte-for-byte.

require 'base64'

module JWT
  class Base64
    class << self
      def url_encode(str)
        # homurabi patch: strip '=' padding manually (Opal base64 has no
        # padding: false option).
        ::Base64.urlsafe_encode64(str.to_s).delete('=')
      end

      def url_decode(str)
        # homurabi patch: upstream catches ArgumentError('invalid base64')
        # when CRuby's urlsafe_decode64 rejects missing padding. Our Opal
        # base64 either pads automatically or errors differently, so we
        # just pad manually up-front — no legacy warning path needed
        # for JWT's `.delete('=')`-stripped signatures (always
        # 43/86/171 chars for HS256/384/512 etc).
        padded = str + ('=' * ((4 - str.length.modulo(4)) % 4))
        ::Base64.urlsafe_decode64(padded)
      rescue ::ArgumentError => e
        raise unless e.message == 'invalid base64'
        raise Base64DecodeError, 'Invalid base64 encoding' if JWT.configuration.strict_base64_decoding

        loose_urlsafe_decode64(str)
      end

      def loose_urlsafe_decode64(str)
        padded = str + ('=' * ((4 - str.length.modulo(4)) % 4))
        ::Base64.decode64(padded.tr('-_', '+/'))
      end
    end
  end
end
