# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def teardown
    Sentiero.reset_configuration!
  end

  def test_geo_source_defaults_to_nil
    assert_nil Sentiero::Configuration.new.geo_source
  end

  def test_geo_source_accepts_cloudflare_and_callable
    config = Sentiero::Configuration.new
    config.geo_source = :cloudflare
    assert_equal :cloudflare, config.geo_source
    config.geo_source = ->(_env) { {} }
    assert_respond_to config.geo_source, :call
    config.geo_source = nil
    assert_nil config.geo_source
  end

  def test_geo_source_rejects_other_values
    config = Sentiero::Configuration.new
    assert_raises(ArgumentError) { config.geo_source = :maxmind }
    assert_raises(ArgumentError) { config.geo_source = "cloudflare" }
  end
end
