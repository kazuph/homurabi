# frozen_string_literal: true

require 'stringio'

class Tempfile < StringIO
  def initialize(*)
    super('')
  end

  def self.open(*)
    raise NotImplementedError, 'Tempfile is stubbed in homura (Workers have no writable FS)'
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
