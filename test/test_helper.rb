# frozen_string_literal: true

if ENV["COVERAGE"] || ENV["CI"]
  require "simplecov"
  SimpleCov.command_name "core"
  SimpleCov.start do
    add_filter "/test/"
    add_filter "/demo/"
    add_filter "/frontend/"
    add_group "Core", "lib/sentiero"
    add_group "Rails", "lib/sentiero/rails"
    enable_coverage :branch
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "sentiero"
