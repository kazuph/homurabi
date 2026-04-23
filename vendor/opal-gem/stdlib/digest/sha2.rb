# frozen_string_literal: true

# Compatibility shim — `digest/sha2` traditionally pulls in
# Digest::SHA256/SHA384/SHA512. `stdlib/digest.rb` defines them already,
# so this file only needs to preserve the conventional require target.
require 'digest'
