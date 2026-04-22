# Minimal Tilt stub for the homura Phase 2 hello-world handler.
#
# Real Sinatra requires the actual `tilt` gem for template rendering
# (ERB, Haml, etc.). janbiedermann does not maintain a tilt fork because
# Tilt's internals (binding manipulation, file IO) are difficult to run
# under Opal as-is.
#
# For Phase 2 we do not render any templates — `get '/' do; "hello"; end`
# returns a String directly and never reaches Tilt. So we provide just
# enough of the Tilt surface area for `require 'tilt'` to succeed and
# for Sinatra::Base to load. If a request actually tries to render a
# template, it will raise an explicit NotImplementedError so the gap is
# obvious and we can grow this stub deliberately in a later phase.

module Tilt
  class TemplateNotFound < StandardError; end

  class Cache
    def initialize
      @cache = {}
    end

    def fetch(*key)
      @cache[key] ||= yield
    end

    def clear
      @cache.clear
    end
  end

  class Mapping
    def initialize
      @extensions = {}
    end

    def register(template_class, *extensions)
      extensions.each { |ext| @extensions[ext.to_s] = template_class }
    end

    def [](name)
      @extensions[name.to_s]
    end

    def extensions_for(engine_or_class)
      @extensions.each_with_object([]) do |(ext, klass), out|
        out << ext if klass == engine_or_class
      end
    end

    def template_for(name)
      @extensions[name.to_s]
    end
  end

  class << self
    def default_mapping
      @default_mapping ||= Mapping.new
    end

    def [](name)
      default_mapping[name]
    end

    def register(template_class, *extensions)
      default_mapping.register(template_class, *extensions)
    end

    def new(file = nil, line = nil, options = {}, &block)
      raise NotImplementedError,
            'Tilt template rendering is not available in homura Phase 2 ' \
            '(stubbed). Return Strings or arrays from your Sinatra handlers.'
    end
  end
end
