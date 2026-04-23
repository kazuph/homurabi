# frozen_string_literal: true

module Rack
  # Rack::MediaType parse media type and parameters out of content_type string

  class MediaType
    SPLIT_PATTERN = /[;,]/

    class << self
      # The media type (type/subtype) portion of the CONTENT_TYPE header
      # without any media type parameters. e.g., when CONTENT_TYPE is
      # "text/plain;charset=utf-8", the media-type is "text/plain".
      #
      # For more information on the use of media types in HTTP, see:
      # http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.7
      # homura patch: Opal Strings are immutable, so #rstrip!/#downcase!/
      # #strip! all raise. Rewritten to use non-mutating String forms.
      def type(content_type)
        return nil unless content_type && !content_type.empty?
        type = content_type.split(SPLIT_PATTERN, 2).first
        type.rstrip.downcase
      end

      def params(content_type)
        return {} if content_type.nil? || content_type.empty?

        content_type.split(SPLIT_PATTERN)[1..-1].each_with_object({}) do |s, hsh|
          s = s.strip
          k, v = s.split('=', 2)
          k = k.downcase
          hsh[k] = strip_doublequotes(v)
        end
      end

      private

      def strip_doublequotes(str)
        (str && str.start_with?('"') && str.end_with?('"')) ? str[1..-2] : str || ''
      end
    end
  end
end
