# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

# Security coverage for the /analytics/forms surface: auth gating and the
# guarantee that masked input values never reach the rendered page. (The shared
# XSS/CSRF/header machinery is exercised in test/web/analytics_app_test.rb.)
class SecurityFormsTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sentiero::Web::AnalyticsApp.new
  end

  def setup
    @store = Sentiero::Stores::Memory.new
    Sentiero.configure do |c|
      c.allow_insecure_dashboard = true
      c.store = @store
      c.auth_callback = nil
      c.analytics_max_scan_sessions = 5000
    end
    Sentiero::Web::Manifest.reset!
  end

  def teardown
    Sentiero.reset_configuration!
  end

  def now_ms
    @now_ms ||= (Time.now.to_f * 1000).round
  end

  def test_forms_requires_auth
    Sentiero.configuration.auth_callback = ->(_env) { false }

    get "/analytics/forms"

    assert_equal 403, last_response.status
  end

  def test_forms_does_not_leak_masked_input_values
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
      {"type" => 3, "timestamp" => now_ms, "data" => {"source" => 5, "id" => 10, "text" => "hunter2-secret"}},
      {"type" => 4, "timestamp" => now_ms + 10, "data" => {"href" => "https://x.test/next", "height" => 800}}
    ])

    get "/analytics/forms"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "hunter2-secret"
  end
end
