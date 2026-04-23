# frozen_string_literal: true

require 'pathname'

module CloudflareWorkers
  module BuildSupport
    RUNTIME_GEM_NAMES = %w[homura-runtime cloudflare-workers-runtime].freeze
    SINATRA_GEM_NAMES = %w[sinatra-homura sinatra-cloudflare-workers].freeze

    class << self
      def loaded_spec(*names, loaded_specs: Gem.loaded_specs)
        names.each do |name|
          spec = loaded_specs[name]
          return spec if spec
        end
        nil
      end

      def runtime_root(current_file:, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(*RUNTIME_GEM_NAMES, loaded_specs: loaded_specs)
        return Pathname(spec.full_gem_path) if spec

        Pathname(current_file).expand_path.join('../..')
      end

      def gem_lib(*names, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(*names, loaded_specs: loaded_specs)
        return File.join(spec.full_gem_path, 'lib') if spec

        raise("cloudflare-workers-build: gem #{names.join(' or ')} not loaded; use bundle exec from app root")
      end

      def vendor_from_gemfile(project_root)
        gf = Pathname(project_root).join('Gemfile')
        return unless gf.file?

        names = Regexp.union(RUNTIME_GEM_NAMES)
        txt = gf.read
        return unless (m = txt.match(/#{names}['"]\s*,\s*path:\s*['"]([^'"]+)['"]/))

        runtime_path = Pathname.new(m[1]).expand_path(project_root)
        vend = runtime_path.join('..', '..', 'vendor').expand_path
        vend if vend.directory?
      end
    end
  end
end
