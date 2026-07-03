# frozen_string_literal: true

require "test_helper"

class GeoTest < Minitest::Test
  def cf_env(extra = {})
    {"HTTP_CF_IPCOUNTRY" => "DE"}.merge(extra)
  end

  def test_nil_source_resolves_empty
    assert_equal({}, Sentiero::Geo.resolve(cf_env, nil))
  end

  def test_cloudflare_country_only
    assert_equal({"geo_country" => "DE"}, Sentiero::Geo.resolve(cf_env, :cloudflare))
  end

  def test_cloudflare_full_headers
    env = cf_env(
      "HTTP_CF_IPCITY" => "Berlin",
      "HTTP_CF_REGION" => "Berlin",
      "HTTP_CF_TIMEZONE" => "Europe/Berlin"
    )
    geo = Sentiero::Geo.resolve(env, :cloudflare)
    assert_equal "DE", geo["geo_country"]
    assert_equal "Berlin", geo["geo_city"]
    assert_equal "Berlin", geo["geo_region"]
    assert_equal "Europe/Berlin", geo["geo_timezone"]
  end

  def test_cloudflare_unknown_and_tor_markers_dropped
    assert_equal({}, Sentiero::Geo.resolve({"HTTP_CF_IPCOUNTRY" => "XX"}, :cloudflare))
    assert_equal({}, Sentiero::Geo.resolve({"HTTP_CF_IPCOUNTRY" => "T1"}, :cloudflare))
  end

  def test_cloudflare_absent_headers_resolve_empty
    assert_equal({}, Sentiero::Geo.resolve({}, :cloudflare))
  end

  def test_proc_source_keys_normalized
    source = ->(env) { {"country" => env["HTTP_X_COUNTRY"], "city" => "Lisbon"} }
    geo = Sentiero::Geo.resolve({"HTTP_X_COUNTRY" => "PT"}, source)
    assert_equal({"geo_country" => "PT", "geo_city" => "Lisbon"}, geo)
  end

  def test_proc_unknown_keys_and_non_string_values_dropped
    source = ->(_env) { {"country" => "US", "latitude" => 52.5, "city" => 42} }
    assert_equal({"geo_country" => "US"}, Sentiero::Geo.resolve({}, source))
  end

  def test_proc_non_hash_return_resolves_empty
    assert_equal({}, Sentiero::Geo.resolve({}, ->(_env) { "US" }))
  end

  def test_raising_proc_resolves_empty
    assert_equal({}, Sentiero::Geo.resolve({}, ->(_env) { raise "geo db down" }))
  end

  def test_values_stripped_and_truncated
    source = ->(_env) { {"city" => "  #{"x" * 300}  "} }
    geo = Sentiero::Geo.resolve({}, source)
    assert_equal 256, geo["geo_city"].length
  end

  def test_blank_values_dropped
    source = ->(_env) { {"country" => "US", "city" => "   "} }
    assert_equal({"geo_country" => "US"}, Sentiero::Geo.resolve({}, source))
  end
end
