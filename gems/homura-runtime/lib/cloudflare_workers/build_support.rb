# frozen_string_literal: true

require 'pathname'

module CloudflareWorkers
  module BuildSupport
    RUNTIME_GEM_NAME = 'homura-runtime'
    SINATRA_GEM_NAME = 'sinatra-homura'

    class << self
      def loaded_spec(name, loaded_specs: Gem.loaded_specs)
        loaded_specs[name]
      end

      def runtime_root(current_file:, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(RUNTIME_GEM_NAME, loaded_specs: loaded_specs)
        return Pathname(spec.full_gem_path) if spec

        Pathname(current_file).expand_path.join('../..')
      end

      def gem_lib(name, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(name, loaded_specs: loaded_specs)
        return File.join(spec.full_gem_path, 'lib') if spec

        raise("cloudflare-workers-build: gem #{name} not loaded; use bundle exec from app root")
      end

      def vendor_from_gemfile(project_root)
        gf = Pathname(project_root).join('Gemfile')
        return unless gf.file?

        txt = gf.read
        return unless (m = txt.match(/#{Regexp.escape(RUNTIME_GEM_NAME)}['"]\s*,\s*path:\s*['"]([^'"]+)['"]/))

        runtime_path = Pathname.new(m[1]).expand_path(project_root)
        vend = runtime_path.join('..', '..', 'vendor').expand_path
        vend if vend.directory?
      end
    end
  end
end
