# Minimal Tempfile stub for homurabi Phase 2.
# Cloudflare Workers do not have a writable filesystem so a real Tempfile
# implementation is impossible. Rack only references Tempfile for
# multipart upload buffering, which is not exercised by the hello-world
# handler. This stub allows `require 'tempfile'` to succeed; calling the
# class will raise an explicit error.

require 'stringio'

class Tempfile < StringIO
  def initialize(*)
    super('')
  end

  def self.open(*)
    raise NotImplementedError, 'Tempfile is stubbed in homurabi Phase 2 (Workers have no writable FS)'
  end

  def path
    raise NotImplementedError, 'Tempfile#path stubbed (no FS)'
  end

  def unlink
    self
  end

  def delete
    self
  end

  def close!
    close
  end
end
