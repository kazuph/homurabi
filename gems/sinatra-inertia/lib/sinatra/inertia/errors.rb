# frozen_string_literal: true

module Sinatra
  module Inertia
    Error = Class.new(StandardError)
    InvalidProtocol = Class.new(Error)
  end
end
