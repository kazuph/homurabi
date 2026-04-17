# frozen_string_literal: true
#
# homurabi patch: vendored from ruby-jwt v2.9.3. We drop CRuby-specific
# helpers (openssl_3?, rbnacl?) that are never true on Workers, keeping
# just the version constant needed by deprecations/compat code paths.

module JWT
  def self.gem_version
    VERSION::STRING
  end

  module VERSION
    MAJOR  = 2
    MINOR  = 9
    TINY   = 3
    PRE    = 'homurabi'

    STRING = [MAJOR, MINOR, TINY, PRE].compact.join('.')
  end

  # homurabi patch: these probes are referenced by vendored code paths
  # (jwa.rb). On Workers, RbNaCl is not available and OpenSSL is our
  # Opal wrapper, not libssl — both helpers return false.
  def self.openssl_3?;                           false; end
  def self.rbnacl?;                              false; end
  def self.rbnacl_6_or_greater?;                 false; end
  def self.openssl_3_hmac_empty_key_regression?; false; end
end
