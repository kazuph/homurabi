# frozen_string_literal: true

require 'fileutils'
require 'pathname'

module CloudflareWorkers
  module BuildSupport
    RUNTIME_GEM_NAME = 'homura-runtime'
    SINATRA_GEM_NAME = 'sinatra-homura'
    SEQUEL_D1_GEM_NAME = 'sequel-d1'

    class << self
      def loaded_spec(name, loaded_specs: Gem.loaded_specs)
        loaded_specs[name]
      end

      def gem_root(name, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(name, loaded_specs: loaded_specs)
        return spec.full_gem_path if spec

        raise("homura build: gem #{name} not loaded; use bundle exec from app root")
      end

      def runtime_root(current_file:, loaded_specs: Gem.loaded_specs)
        spec = loaded_spec(RUNTIME_GEM_NAME, loaded_specs: loaded_specs)
        return Pathname(spec.full_gem_path) if spec

        Pathname(current_file).expand_path.join('../..')
      end

      def gem_lib(name, loaded_specs: Gem.loaded_specs)
        File.join(gem_root(name, loaded_specs: loaded_specs), 'lib')
      end

      def gem_vendor(name, loaded_specs: Gem.loaded_specs)
        vendor = File.join(gem_root(name, loaded_specs: loaded_specs), 'vendor')
        return vendor if Dir.exist?(vendor)

        nil
      end

      def runtime_file(*names, current_file: __FILE__, loaded_specs: Gem.loaded_specs)
        runtime_root(current_file: current_file, loaded_specs: loaded_specs).join('runtime', *names)
      end

      def ensure_standalone_runtime(project_root, current_file: __FILE__, loaded_specs: Gem.loaded_specs)
        target_dir = Pathname(project_root).join('cf-runtime')
        FileUtils.mkdir_p(target_dir)

        %w[setup-node-crypto.mjs worker_module.mjs].each do |name|
          FileUtils.cp(runtime_file(name, current_file: current_file, loaded_specs: loaded_specs), target_dir.join(name))
        end

        target_dir
      end

      def standalone_load_paths(project_root, with_db:, loaded_specs: Gem.loaded_specs)
        root = Pathname(project_root)
        load_paths = []

        hv = vendor_from_gemfile(root)
        load_paths << hv.to_s if hv

        load_paths += ['.', 'build/auto_await', 'build/auto_await/app', 'app']
        [
          gem_lib(RUNTIME_GEM_NAME, loaded_specs: loaded_specs),
          gem_vendor(RUNTIME_GEM_NAME, loaded_specs: loaded_specs),
          gem_lib(SINATRA_GEM_NAME, loaded_specs: loaded_specs),
          gem_vendor(SINATRA_GEM_NAME, loaded_specs: loaded_specs)
        ].compact.each do |path|
          load_paths << path
        end

        if with_db
          [
            gem_vendor(SEQUEL_D1_GEM_NAME, loaded_specs: loaded_specs),
            gem_lib(SEQUEL_D1_GEM_NAME, loaded_specs: loaded_specs)
          ].compact.each do |path|
            load_paths << path
          end
        end

        load_paths << 'vendor' if root.join('vendor').directory?
        load_paths << 'build'
        load_paths.uniq
      end

      def standalone_namespace(project_root, suffix)
        base = Pathname(project_root).basename.to_s
        parts = base.split(/[^A-Za-z0-9]+/).reject(&:empty?)
        module_name = parts.map { |part| part[0].upcase + part[1..].to_s }.join
        module_name = 'App' if module_name.empty?
        module_name = "App#{module_name}" if module_name.match?(/\A\d/)
        "#{module_name}#{suffix}"
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
