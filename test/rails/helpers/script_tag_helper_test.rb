# frozen_string_literal: true

require_relative "../test_helper"

class Sentiero::Rails::Helpers::ScriptTagHelperTest < Minitest::Test
  include Sentiero::Rails::Helpers::ScriptTagHelper

  def setup
    Sentiero.reset_configuration!
    Sentiero::Rails.reset_configuration!
    Sentiero.configuration.store = Sentiero::Stores::Memory.new
  end

  def teardown
    Sentiero.reset_configuration!
    Sentiero::Rails.reset_configuration!
  end

  def test_produces_script_tags
    result = sentiero_script_tag
    assert_includes result, '<script type="application/json" id="sentiero-config">'
    assert_includes result, "sentiero/events"
    assert_includes result, "<script src="
  end

  def test_uses_configured_events_url
    Sentiero::Rails.configuration.events_url = "/custom/events"
    result = sentiero_script_tag
    assert_includes result, "/custom/events"
  end

  def test_allows_override_events_url
    result = sentiero_script_tag(events_url: "/override/events")
    assert_includes result, "/override/events"
  end

  def test_output_is_html_safe
    result = sentiero_script_tag
    assert result.html_safe?, "Expected output to be html_safe"
  end

  def test_includes_respect_gpc_when_enabled
    Sentiero.configuration.respect_gpc = true
    result = sentiero_script_tag
    assert_includes result, "\"respectGpc\":true"
  end

  def test_omits_respect_gpc_when_disabled
    Sentiero.configuration.respect_gpc = false
    result = sentiero_script_tag
    refute_includes result, "respectGpc"
  end
end
