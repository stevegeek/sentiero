# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter"

module Sentiero
  # One entry point for the separate config objects: the core config exposes the
  # Reporter (and Rails) config so all three are reachable and resettable together,
  # while the sub-configs stay independent (the reporter is usable standalone).
  class ConfigConsolidationTest < Minitest::Test
    def teardown = Sentiero.reset_all_configuration!

    def test_reporter_accessor_returns_the_reporter_config
      assert_same Sentiero::Reporter.configuration, Sentiero.configuration.reporter
    end

    def test_configure_block_can_reach_the_reporter_config
      Sentiero.configure { |c| c.reporter.project = "shop" }
      assert_equal "shop", Sentiero::Reporter.configuration.project
    end

    def test_reset_all_configuration_resets_core_and_reporter
      Sentiero.configuration.retention_period = 99
      Sentiero::Reporter.configuration.project = "shop"

      Sentiero.reset_all_configuration!

      assert_nil Sentiero.configuration.retention_period
      assert_nil Sentiero::Reporter.configuration.project
    end
  end
end
