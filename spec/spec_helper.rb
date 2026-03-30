# frozen_string_literal: true

require "sentiero"
require "rack/test"

RSpec.configure do |config|
  config.before(:each) do
    Sentiero.reset_configuration!
  end
end
