# frozen_string_literal: true

require "test_helper"
require "sentiero"
require "sentiero/stores/memory"
require "rack"
require "rack/test"
require "json"

module Sentiero
  # Exercises the apps composed the way a real standalone deployment mounts
  # them (ingest endpoints as siblings of the dashboard). Guards against
  # routing collisions that isolated per-app tests cannot see — e.g. the
  # dashboard events page must live at /custom-events, NOT shadow the ingest
  # at /events.
  class CombinedMountTest < Minitest::Test
    include Rack::Test::Methods

    def app
      @app ||= Rack::Builder.new do
        map("/sentiero/errors") { run Sentiero::Web::ErrorsApp.new }
        map("/sentiero/track") { run Sentiero::Web::TrackApp.new }
        map("/sentiero/events") { run Sentiero::Web::EventsApp.new }
        map("/sentiero") { run Sentiero::Web::DashboardApp.new }
      end.to_app
    end

    def setup
      Sentiero.configure do |c|
        c.allow_insecure_dashboard = true
        c.store = Stores::Memory.new
        c.ingest_keys = {"k1" => "app"}
        c.auth_callback = nil
        c.cors_origins = []
      end
      Sentiero::Web::Manifest.reset! if Sentiero::Web::Manifest.respond_to?(:reset!)
    end

    def teardown
      Sentiero.reset_configuration!
    end

    def bearer
      {"HTTP_AUTHORIZATION" => "Bearer k1", "CONTENT_TYPE" => "application/json"}
    end

    def test_server_error_ingest_is_visible_in_dashboard
      post "/sentiero/errors",
        JSON.generate({"exception_class" => "RuntimeError", "message" => "combined boom",
          "backtrace" => ["app/x.rb:1"], "session_id" => "sess_c"}), bearer
      assert_equal 200, last_response.status
      fingerprint = JSON.parse(last_response.body)["fingerprint"]

      # The dashboard issues UI lives at /issues precisely so it does NOT collide
      # with the public /errors ingest mount (the /events vs /custom-events
      # family). Exercise it directly against a DashboardApp with SCRIPT_NAME set.
      dash = Web::DashboardApp.new

      status, _, body = dash.call(Rack::MockRequest.env_for("/issues", "SCRIPT_NAME" => "/sentiero"))
      assert_equal 200, status
      assert_includes body.join, "combined boom"

      status, _, body = dash.call(Rack::MockRequest.env_for("/issues/#{fingerprint}", "SCRIPT_NAME" => "/sentiero"))
      assert_equal 200, status
      assert_includes body.join, "combined boom"
    end

    # Regression guard: the error-ingest endpoint owns /sentiero/errors, so a GET
    # there is the ingest's 405 — never a dashboard page. Mirrors the
    # /events-vs-/custom-events contract. (The dashboard issues UI is /issues
    # inside DashboardApp, deliberately off /errors to avoid this collision.)
    def test_errors_path_is_the_ingest_not_the_dashboard_in_flat_mount
      get "/sentiero/errors"
      assert_equal 405, last_response.status
    end

    def test_custom_events_page_reachable_through_combined_mount
      # Regression guard for the /events collision: the dashboard events page
      # at /custom-events must NOT be shadowed by the sibling EventsApp ingest.
      post "/sentiero/track", JSON.generate({"name" => "combined_event", "level" => "info"}), bearer
      assert_equal 200, last_response.status

      get "/sentiero/custom-events"
      assert_equal 200, last_response.status
      assert_includes last_response.body, "combined_event"
    end

    def test_events_path_is_the_ingest_not_the_dashboard
      # /sentiero/events is the browser ingest (POST-only). A GET must be 405
      # (the ingest), never a dashboard page — this locks the contract that the
      # dashboard events view lives at /custom-events.
      get "/sentiero/events"
      assert_equal 405, last_response.status

      post "/sentiero/events",
        JSON.generate({"sessionId" => "sess_c", "windowId" => "win_1",
          "events" => [{"type" => 3, "timestamp" => 1000}]}),
        {"CONTENT_TYPE" => "application/json"}
      assert_equal 200, last_response.status
    end

    # Nav rendering is exercised against DashboardApp directly at /issues (the
    # dashboard issues UI; /sentiero/errors is the ingest in this flat mount).
    def test_nav_lights_errors_for_problems_and_client_errors
      _, _, body = Web::DashboardApp.new.call(Rack::MockRequest.env_for("/issues", "SCRIPT_NAME" => "/sentiero"))
      body = body.join
      assert_includes body, ">Errors<" # nav label renamed
      # the Errors nav <a> carries active; Analytics does not
      assert_match %r{s-nav-item active[^>]*>\s*<svg[^>]*>.*?</svg>\s*Errors}m, body
    end

    def test_nav_lights_errors_not_analytics_on_client_errors_page
      _, _, body = Web::DashboardApp.new.call(Rack::MockRequest.env_for("/issues?source=client", "SCRIPT_NAME" => "/sentiero"))
      body = body.join
      # The Analytics nav link must NOT carry the active class on the
      # client-errors page (Errors owns this route). Match the Analytics <a>
      # tag directly rather than relying on svg ordering.
      refute_match %r{<a class="s-nav-item active"[^>]*href="[^"]*/analytics">}, body
      # And Errors must be the active nav item here.
      assert_match %r{<a class="s-nav-item active"[^>]*href="[^"]*/issues">}, body
    end

    def test_dashboard_index_and_replay_reachable_in_combined_mount
      post "/sentiero/events",
        JSON.generate({"sessionId" => "sess_c", "windowId" => "win_1",
          "events" => [{"type" => 2, "timestamp" => 1000}, {"type" => 3, "timestamp" => 1001}]}),
        {"CONTENT_TYPE" => "application/json"}
      assert_equal 200, last_response.status

      get "/sentiero/"
      assert_equal 200, last_response.status

      get "/sentiero/sessions/sess_c/windows/win_1"
      assert_equal 200, last_response.status
    end
  end
end
