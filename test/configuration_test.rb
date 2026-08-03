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

  def test_max_body_size_default
    assert_equal 524_288, Sentiero::Configuration.new.max_body_size
  end

  def test_max_body_size_accepts_a_positive_integer
    config = Sentiero::Configuration.new
    config.max_body_size = 2_000_000
    assert_equal 2_000_000, config.max_body_size
  end

  # nil/zero/negative/non-numeric would crash BodyReader (or silently reject
  # every request) on the public events endpoint, so bad values fall back to
  # the default like the session rotation writers do.
  def test_max_body_size_falls_back_to_default_for_invalid_values
    [nil, 0, -5, "500", Float::INFINITY].each do |bad|
      config = Sentiero::Configuration.new
      config.max_body_size = bad
      assert_equal 524_288, config.max_body_size, "expected fallback for #{bad.inspect}"
    end
  end
end
