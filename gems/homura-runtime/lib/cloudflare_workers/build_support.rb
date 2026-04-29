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
        # The homura runtime needs two .mjs glue files alongside the
        # generated `worker.entrypoint.mjs`. Until 0.2.22 we wrote them
        # to `cf-runtime/` at the project root, which made every Ruby
        # repo carry two opaque JS files in source control. Hide them
        # under `build/cf-runtime/` so the build artifact tree owns
        # them — `build/` is already in the example .gitignore template.
        target_dir = Pathname(project_root).join('build', 'cf-runtime')
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

        # Pick up any other gems that should ship in the Workers bundle:
        #
        #   * `path:`-resolved gems in the consumer's Gemfile (monorepo
        #     dev mode), and
        #   * RubyGems-installed gems that opt in via
        #     `spec.metadata['homura.auto_await'] = 'true'`.
        #
        # Both go through the same auto-await pass during `homura-build`,
        # and we prefer the rewritten copy under
        # `build/auto_await/gem_<basename>/lib` if present so async chains
        # inside gem code get `__await__` inserted just like consumer
        # app code.
        opal_gem_paths(root, loaded_specs: loaded_specs).each do |gem_path|
          basename = gem_path.basename.to_s
          rewritten_lib = root.join('build', 'auto_await', "gem_#{basename}", 'lib')
          load_paths << rewritten_lib.to_s if rewritten_lib.directory?
          %w[lib vendor].each do |sub|
            dir = gem_path.join(sub)
            load_paths << dir.to_s if dir.directory?
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

      # Returns the union of `path_gemfile_entries(project_root)` and any
      # bundled gems that opt in to the Opal pipeline via
      # `spec.metadata['homura.auto_await']`. This is the single source
      # of truth for both `standalone_load_paths` and the auto-await pass
      # that `homura-build` runs. Returns `Pathname` objects pointing at
      # each gem's root directory.
      def opal_gem_paths(project_root, loaded_specs: Gem.loaded_specs)
        wired = [RUNTIME_GEM_NAME, SINATRA_GEM_NAME, SEQUEL_D1_GEM_NAME]
        out = []
        out.concat(path_gemfile_entries(project_root))

        loaded_specs.each_value do |spec|
          next if wired.include?(spec.name)
          meta = spec.metadata
          next unless meta.is_a?(Hash)
          flag = meta['homura.auto_await']
          next unless flag == 'true' || flag == true
          next if spec.full_gem_path.nil?
          gem_path = Pathname(spec.full_gem_path)
          out << gem_path if gem_path.directory?
        end

        out.uniq
      end

      # Returns absolute Pathnames for every `path:`-declared gem in the
      # project's Gemfile that should ship in the Workers bundle.
      #
      # Excludes:
      # * gems we already wire in explicitly
      #   (homura-runtime / sinatra-homura / sequel-d1)
      # * `require: false` gems (dev tooling like `gem 'rspec', path: ..., require: false`)
      # * gems declared inside `group :development do … end` /
      #   `group :test do … end` blocks (they don't ship to production)
      EXCLUDED_GROUPS = %i[development test dev_test development_test ci tools].freeze

      def path_gemfile_entries(project_root)
        gf = Pathname(project_root).join('Gemfile')
        return [] unless gf.file?

        wired = [RUNTIME_GEM_NAME, SINATRA_GEM_NAME, SEQUEL_D1_GEM_NAME]
        out = []
        group_stack = []

        gf.read.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')

          if (m = stripped.match(/\Agroup\s+(.+?)\s+do\b/))
            groups = m[1].scan(/[:'"]([A-Za-z0-9_]+)['"]?/).flatten.map(&:to_sym)
            group_stack.push(groups)
            next
          end
          if stripped == 'end'
            group_stack.pop unless group_stack.empty?
            next
          end

          next if group_stack.flatten.any? { |g| EXCLUDED_GROUPS.include?(g) }

          m = line.match(/gem\s+['"]([^'"]+)['"][^#]*?path:\s*['"]([^'"]+)['"]/)
          next unless m
          name, rel = m[1], m[2]
          next if wired.include?(name)
          next if line.match?(/require:\s*false/)

          gem_path = Pathname.new(rel).expand_path(project_root)
          out << gem_path if gem_path.directory?
        end
        out.uniq
      end
    end
  end
end
