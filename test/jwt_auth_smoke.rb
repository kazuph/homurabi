# frozen_string_literal: true
# backtick_javascript: true
#
# Phase 17.5 — Sinatra::JwtAuth halt-boundary smoke tests.
#
# Verifies that authenticate_or_401 returns a safe [status, body] tuple
# instead of throwing halt across the async boundary.
#
# Usage:
#   npm run test:jwt-auth
#   npm test

require 'json'
require 'digest'
require 'digest/sha2'
require 'openssl'
require 'securerandom'
require 'base64'

# vendor/ 配下の jwt を読めるようにする
$LOAD_PATH.unshift(File.expand_path('../vendor', __dir__))
require 'jwt'

# CRuby 上では __await__ は定義されていない（Opal 専用）。
# テスト用に no-op を定義しておく。
module Kernel
  def __await__
    self
  end
end

# Load the Sinatra::JwtAuth helpers in isolation
$LOAD_PATH.unshift(File.expand_path('../gems/sinatra-homura/lib', __dir__))
require 'sinatra/jwt_auth'

module SmokeTest
  @passed = 0
  @failed = 0
  @errors = []

  def self.assert(label, &block)
    result = block.call
    if result
      @passed += 1
      $stdout.puts "  PASS  #{label}"
    else
      @failed += 1
      @errors << label
      $stderr.puts "  FAIL  #{label}"
    end
  rescue => e
    @failed += 1
    @errors << "#{label} (#{e.class}: #{e.message})"
    $stderr.puts "  ERROR #{label} — #{e.class}: #{e.message}"
  end

  def self.summary
    total = @passed + @failed
    $stdout.puts "\n#{total} tests, #{@passed} passed, #{@failed} failed"
    exit(@failed.positive? ? 1 : 0)
  end
end

# Minimal mock request / settings for helper tests
class MockSettings
  def jwt_secret
    'test-secret'
  end

  def jwt_algorithm
    'HS256'
  end

  def jwt_verify_key
    nil
  end

  def jwt_sign_key
    nil
  end
end

class MockRequest
  attr_accessor :env

  def initialize(env = {})
    @env = env
  end
end

class MockHelper
  include Sinatra::JwtAuth::Helpers

  attr_accessor :request

  def settings
    MockSettings.new
  end

  def initialize(request)
    @request = request
  end
end

$stdout.puts "Sinatra::JwtAuth Halt-Boundary Smoke Tests"
$stdout.puts "=" * 40

# 1. authenticate_or_401 returns [nil, payload] for a valid token
SmokeTest.assert("authenticate_or_401 returns [nil, payload] for valid token") do
  token = JWT.encode({ 'sub' => 'alice' }, 'test-secret', 'HS256')
  req = MockRequest.new('HTTP_AUTHORIZATION' => "Bearer #{token}")
  helper = MockHelper.new(req)
  status, payload = helper.authenticate_or_401
  status.nil? && payload.is_a?(Hash) && payload['sub'] == 'alice'
end

# 2. authenticate_or_401 returns [401, json] for missing token
SmokeTest.assert("authenticate_or_401 returns [401, json] for missing token") do
  req = MockRequest.new({})
  helper = MockHelper.new(req)
  status, body = helper.authenticate_or_401
  status == 401 && body.include?('missing bearer token')
end

# 3. authenticate_or_401 returns [401, json] for expired token
SmokeTest.assert("authenticate_or_401 returns [401, json] for expired token") do
  token = JWT.encode({ 'sub' => 'alice', 'exp' => Time.now.to_i - 10 }, 'test-secret', 'HS256')
  req = MockRequest.new('HTTP_AUTHORIZATION' => "Bearer #{token}")
  helper = MockHelper.new(req)
  status, body = helper.authenticate_or_401
  status == 401 && body.include?('token expired')
end

# 4. authenticate_or_401 returns [401, json] for bad signature
SmokeTest.assert("authenticate_or_401 returns [401, json] for bad signature") do
  token = JWT.encode({ 'sub' => 'alice' }, 'wrong-secret', 'HS256')
  req = MockRequest.new('HTTP_AUTHORIZATION' => "Bearer #{token}")
  helper = MockHelper.new(req)
  status, body = helper.authenticate_or_401
  status == 401 && body.include?('signature verification failed')
end

# 5. authenticate_or_401 sets @jwt_payload on success
SmokeTest.assert("authenticate_or_401 sets @jwt_payload on success") do
  token = JWT.encode({ 'sub' => 'alice' }, 'test-secret', 'HS256')
  req = MockRequest.new('HTTP_AUTHORIZATION' => "Bearer #{token}")
  helper = MockHelper.new(req)
  helper.authenticate_or_401
  helper.jwt_payload['sub'] == 'alice'
end

# 6. authenticate_or_401 does NOT use halt (no throw)
SmokeTest.assert("authenticate_or_401 does not raise or throw") do
  req = MockRequest.new({})
  helper = MockHelper.new(req)
  begin
    status, body = helper.authenticate_or_401
    status == 401
  rescue => e
    false
  end
end

SmokeTest.summary
