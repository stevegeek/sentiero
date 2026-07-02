# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Load sentiero and sentiero-rails from the local source
$LOAD_PATH.unshift File.expand_path("../../../../lib", __dir__)
require "sentiero"
require "sentiero/rails"

module SentieroTest
  class Application < ::Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.active_support.deprecation = :stderr
    config.secret_key_base = "test_secret_key_base_for_sentiero_rails_tests"
    config.hosts.clear

    if Rails.env.test?
      config.action_controller.allow_forgery_protection = false
      config.log_level = :warn
    end
  end
end
