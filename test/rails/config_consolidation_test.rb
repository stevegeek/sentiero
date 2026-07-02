# frozen_string_literal: true

require_relative "test_helper"

class Sentiero::Rails::ConfigConsolidationTest < Minitest::Test
  def teardown = Sentiero.reset_all_configuration!

  def test_rails_accessor_returns_the_rails_config
    assert_same Sentiero::Rails.configuration, Sentiero.configuration.rails
  end

  def test_reset_all_configuration_resets_rails
    Sentiero::Rails.configuration.events_url = "/custom/events"
    Sentiero.reset_all_configuration!
    assert_equal "/sentiero/events", Sentiero::Rails.configuration.events_url
  end
end
