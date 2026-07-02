# frozen_string_literal: true

require_relative "test_helper"

class RedactionConfigIntegrationTest < Minitest::Test
  def setup
    Sentiero.reset_configuration!
  end

  def test_default_redaction_config
    assert_instance_of Sentiero::Redaction::Config, Sentiero.configuration.redaction
    assert_equal :strip, Sentiero.configuration.redaction.url_mode
  end

  def test_sanitize_events_removed
    refute_respond_to Sentiero.configuration, :sanitize_events
  end
end
