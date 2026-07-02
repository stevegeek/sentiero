# frozen_string_literal: true

SentieroTest::Application.configure do
  config.cache_classes = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :all
  config.log_level = :debug
end
