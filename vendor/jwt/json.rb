# frozen_string_literal: true
#
# homura patch: verbatim from ruby-jwt v2.9.3. Opal's JSON corelib
# implements ::JSON.generate / ::JSON.parse with CRuby semantics that
# are compatible for the shapes JWT uses (Hash / Array / String / Numeric).

require 'json'

module JWT
  class JSON
    class << self
      def generate(data)
        ::JSON.generate(data)
      end

      def parse(data)
        ::JSON.parse(data)
      end
    end
  end
end
