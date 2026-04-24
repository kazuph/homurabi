# frozen_string_literal: true

# Phase 15-A — thin wrappers around the generic build CLIs.
# `npm run build` / `bundle exec homura build` is the primary entry point.

GEM_ERB = 'gems/homura-runtime/exe/compile-erb'
PATCH   = 'gems/homura-runtime/runtime/patch-opal-evals.mjs'

desc 'Compile ERB templates into build/homura_templates.rb'
task 'build:erb' do
  sh 'ruby', GEM_ERB, '--input', 'views', '--output', 'build/homura_templates.rb', '--namespace', 'HomuraTemplates'
end

GEM_ASSETS = 'gems/homura-runtime/exe/compile-assets'

desc 'Embed public/ assets into build/homura_assets.rb'
task 'build:assets' do
  sh 'ruby', GEM_ASSETS, '--input', 'public', '--output', 'build/homura_assets.rb', '--namespace', 'HomuraAssets'
end

desc 'Compile Opal bundle (same argv/env contract as npm run build:opal)'
task 'build:opal' do
  out = ENV.fetch('HOMURA_OPAL_OUTPUT', 'build/hello.no-exit.mjs')
  inp = ENV.fetch('HOMURA_OPAL_INPUT', 'app/hello.rb')
  patch = ENV.fetch('HOMURA_OPAL_PATCH_INPUT', out)
  File.open('build/opal.stderr.log', 'w') do |err_io|
    ok = system(
      { 'OPAL_PREFORK_DISABLE' => '1' },
      'bundle', 'exec', 'opal',
      '-c', '-E', '--esm', '--no-source-map',
      '-I', 'app', '-I', 'gems/homura-runtime/lib', '-I', 'gems/sinatra-homura/lib', '-I', 'gems/sequel-d1/lib', '-I', 'lib', '-I', 'vendor', '-I', 'build',
      '-r', 'opal_patches', '-r', 'cloudflare_workers', '-r', 'homura_templates', '-r', 'homura_assets',
      '-o', out, inp,
      err: err_io
    )
    fail 'opal compile failed (see build/opal.stderr.log)' unless ok
  end
  sh 'node', PATCH, patch
end

desc 'Full homura build (ERB + assets + Opal + patch + worker.entrypoint.mjs)'
task :build do
  sh 'bundle', 'exec', 'homura', 'build'
end

desc 'Regenerate docs search index (public/docs-search-index.json)'
task 'docs:search_index' do
  sh 'ruby', 'bin/generate-docs-search-index'
end

task default: :build
