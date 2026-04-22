# frozen_string_literal: true
# Compatibility shim — `digest/sha2` traditionally pulls in
# Digest::SHA256/SHA384/SHA512. Phase 7 defines them in vendor/digest.rb,
# so we just re-require digest and rely on the existing constants.
require 'digest'
