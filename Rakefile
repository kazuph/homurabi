# frozen_string_literal: true

# Phase 15-A — thin wrappers around the generic build CLIs.
# `npm run build` remains the primary entry point; these tasks exist
# for gem / CI documentation parity (see docs/TOOLCHAIN_CONTRACT.md).

desc 'Compile ERB templates into build/homurabi_templates.rb'
task 'build:erb' do
  sh 'ruby', 'bin/compile-erb', '--input', 'views', '--output', 'build/homurabi_templates.rb', '--namespace', 'HomurabiTemplates'
end

desc 'Embed public/ assets into build/homurabi_assets.rb'
task 'build:assets' do
  sh 'ruby', 'bin/compile-assets', '--input', 'public', '--output', 'build/homurabi_assets.rb', '--namespace', 'HomurabiAssets'
end

desc 'Compile Opal bundle (same argv/env contract as npm run build:opal)'
task 'build:opal' do
  out = ENV.fetch('HOMURABI_OPAL_OUTPUT', 'build/hello.no-exit.mjs')
  inp = ENV.fetch('HOMURABI_OPAL_INPUT', 'app/hello.rb')
  patch = ENV.fetch('HOMURABI_OPAL_PATCH_INPUT', out)
  # argv form avoids shell interpolation on paths that may contain spaces.
  File.open('build/opal.stderr.log', 'w') do |err_io|
    ok = system(
      { 'OPAL_PREFORK_DISABLE' => '1' },
      'bundle', 'exec', 'opal',
      '-c', '-E', '--esm', '--no-source-map',
      '-I', 'app', '-I', 'gems/cloudflare-workers-runtime/lib', '-I', 'gems/sinatra-cloudflare-workers/lib', '-I', 'gems/sequel-d1/lib', '-I', 'lib', '-I', 'vendor', '-I', 'build',
      '-r', 'opal_patches', '-r', 'cloudflare_workers', '-r', 'homurabi_templates', '-r', 'homurabi_assets',
      '-o', out, inp,
      err: err_io
    )
    fail 'opal compile failed (see build/opal.stderr.log)' unless ok
  end
  sh 'node', 'bin/patch-opal-evals.mjs', patch
end

desc 'ERB + assets + Opal (matches npm run build)'
task build: %w[build:erb build:assets build:opal]

task default: :build
