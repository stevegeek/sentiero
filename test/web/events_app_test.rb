# frozen_string_literal: true

require "test_helper"
require "sentiero/web/events_app"
require "rack/test"
require "zlib"
require "stringio"
require "json"

module Sentiero
  module Web
    class EventsAppTest < Minitest::Test
      include Rack::Test::Methods

      def app
        EventsApp.new
      end

      def setup
        Sentiero.configure do |c|
          c.store = Stores::Memory.new
          c.cors_origins = []
        end
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def valid_payload
        {
          "sessionId" => "sess-1",
          "windowId" => "win-1",
          "events" => [{"type" => 3, "timestamp" => 1000}]
        }
      end

      def test_post_valid_events_returns_200
        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        body = JSON.parse(last_response.body)
        assert_equal "ok", body["status"]
      end

      def test_post_valid_events_saves_to_store
        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        assert_equal 1, events.size
        assert_equal 3, events.first["type"]
      end

      def test_post_gzip_compressed_events_returns_200
        json = JSON.generate(valid_payload)
        compressed = gzip_compress(json)

        post "/", compressed, {
          "CONTENT_TYPE" => "application/json",
          "HTTP_CONTENT_ENCODING" => "gzip"
        }

        assert_equal 200, last_response.status
        body = JSON.parse(last_response.body)
        assert_equal "ok", body["status"]

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        assert_equal 1, events.size
      end

      def test_post_oversized_body_returns_413
        oversized = valid_payload.merge("events" => [{"data" => "x" * 600_000}])
        post "/", JSON.generate(oversized), {"CONTENT_TYPE" => "application/json"}

        assert_equal 413, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "too large"
      end

      def test_post_invalid_json_returns_400
        post "/", "not-json{{{", {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_equal "invalid JSON body", body["error"]
      end

      def test_post_missing_session_id_returns_400
        payload = valid_payload.tap { |p| p.delete("sessionId") }
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_empty_session_id_returns_400
        payload = valid_payload.merge("sessionId" => "")
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_uuid_style_ids_pass_validation
        payload = valid_payload.merge(
          "sessionId" => "550e8400-e29b-41d4-a716-446655440000",
          "windowId" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        )
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
      end

      def test_post_alphanumeric_underscore_hyphen_ids_pass_validation
        payload = valid_payload.merge(
          "sessionId" => "sess_abc-123",
          "windowId" => "win_XYZ-789"
        )
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
      end

      def test_post_session_id_with_colons_returns_400
        payload = valid_payload.merge("sessionId" => "sess:bad:id")
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_session_id_with_slashes_returns_400
        payload = valid_payload.merge("sessionId" => "sess/bad/id")
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_session_id_with_spaces_returns_400
        payload = valid_payload.merge("sessionId" => "sess bad id")
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_window_id_with_special_characters_returns_400
        payload = valid_payload.merge("windowId" => "win@bad!id")
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "windowId"
      end

      def test_post_session_id_exceeding_128_chars_returns_400
        payload = valid_payload.merge("sessionId" => "a" * 129)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "sessionId"
      end

      def test_post_window_id_exceeding_128_chars_returns_400
        payload = valid_payload.merge("windowId" => "b" * 129)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "windowId"
      end

      def test_post_session_id_at_128_chars_passes_validation
        payload = valid_payload.merge("sessionId" => "a" * 128)
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
      end

      def test_post_missing_window_id_returns_400
        payload = valid_payload.tap { |p| p.delete("windowId") }
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "windowId"
      end

      def test_post_missing_events_returns_400
        payload = valid_payload.tap { |p| p.delete("events") }
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "events"
      end

      def test_post_empty_events_array_returns_400
        payload = valid_payload.merge("events" => [])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "events"
      end

      def test_options_returns_204_with_cors_headers
        Sentiero.configuration.cors_origins = ["https://example.com"]

        options "/", nil, {"HTTP_ORIGIN" => "https://example.com"}

        assert_equal 204, last_response.status
        assert_equal "POST", last_response.headers["access-control-allow-methods"]
        assert_includes last_response.headers["access-control-allow-headers"], "Content-Type"
        assert_includes last_response.headers["access-control-allow-headers"], "Content-Encoding"
        assert_equal "86400", last_response.headers["access-control-max-age"]
        assert_equal "https://example.com", last_response.headers["access-control-allow-origin"]
      end

      def test_post_with_valid_origin_includes_cors_headers
        Sentiero.configuration.cors_origins = ["https://myapp.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://myapp.com"
        }

        assert_equal 200, last_response.status
        assert_equal "https://myapp.com", last_response.headers["access-control-allow-origin"]
        assert_equal "Origin", last_response.headers["vary"]
      end

      def test_post_with_invalid_origin_excludes_cors_headers
        Sentiero.configuration.cors_origins = ["https://myapp.com"]

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://evil.com"
        }

        assert_equal 200, last_response.status
        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_post_with_no_cors_origins_excludes_cors_headers
        Sentiero.configuration.cors_origins = []

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_ORIGIN" => "https://anything.com"
        }

        assert_equal 200, last_response.status
        assert_nil last_response.headers["access-control-allow-origin"]
      end

      def test_get_returns_405
        get "/"

        assert_equal 405, last_response.status
        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "method not allowed"
      end

      def test_post_gzip_bomb_returns_413
        large_events = [{"data" => "x" * 600_000}]
        large_json = JSON.generate({
          "sessionId" => "sess-1",
          "windowId" => "win-1",
          "events" => large_events
        })
        compressed = gzip_compress(large_json)

        assert compressed.bytesize < BodyReader::MAX_BODY_SIZE,
          "compressed payload should be smaller than MAX_BODY_SIZE for this test to be meaningful"
        assert large_json.bytesize > BodyReader::MAX_BODY_SIZE,
          "decompressed payload should exceed MAX_BODY_SIZE"

        post "/", compressed, {
          "CONTENT_TYPE" => "application/json",
          "HTTP_CONTENT_ENCODING" => "gzip"
        }

        assert_equal 413, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "too large"
      end

      def test_post_oversized_non_gzip_body_returns_413
        oversized_body = "x" * (BodyReader::MAX_BODY_SIZE + 1)

        post "/", oversized_body, {"CONTENT_TYPE" => "application/json"}

        assert_equal 413, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "too large"
      end

      def test_post_invalid_gzip_returns_generic_error
        post "/", "not-valid-gzip-data", {
          "CONTENT_TYPE" => "application/json",
          "HTTP_CONTENT_ENCODING" => "gzip"
        }

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_equal "invalid gzip encoding", body["error"]
        refute_includes body["error"], "Zlib"
        refute_includes body["error"], "not in gzip"
      end

      def test_post_events_with_null_elements_returns_400
        payload = valid_payload.merge("events" => [nil, nil, "string"])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "events must be a non-empty array of objects"
      end

      def test_post_events_with_string_element_returns_400
        payload = valid_payload.merge("events" => ["not a hash"])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "events must be a non-empty array of objects"
      end

      def test_post_events_with_mixed_hash_and_non_hash_returns_400
        payload = valid_payload.merge("events" => [{"type" => 1}, 42, {"type" => 2}])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 400, last_response.status
        body = JSON.parse(last_response.body)
        assert_includes body["error"], "events must be a non-empty array of objects"
      end

      def test_post_events_with_string_timestamps_normalizes_to_floats
        payload = valid_payload.merge("events" => [
          {"type" => 3, "timestamp" => "1000.5"},
          {"type" => 4, "timestamp" => "2000"}
        ])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        assert_equal 2, events.size
        assert_equal 1000.5, events[0]["timestamp"]
        assert_equal 2000.0, events[1]["timestamp"]
        assert_kind_of Float, events[0]["timestamp"]
        assert_kind_of Float, events[1]["timestamp"]
      end

      def test_post_events_with_integer_timestamps_normalizes_to_floats
        payload = valid_payload.merge("events" => [
          {"type" => 3, "timestamp" => 1000}
        ])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        assert_equal 1, events.size
        assert_equal 1000.0, events[0]["timestamp"]
        assert_kind_of Float, events[0]["timestamp"]
      end

      def test_post_events_without_timestamps_leaves_them_unset
        payload = valid_payload.merge("events" => [
          {"type" => 3}
        ])
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        events = Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
        assert_equal 1, events.size
        assert_nil events[0]["timestamp"]
      end

      def test_post_propagates_store_errors_as_500
        failing_store = Minitest::Mock.new
        failing_store.expect(:save_events, nil) { raise "store connection lost" }
        Sentiero.configuration.store = failing_store

        assert_raises(RuntimeError) do
          post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}
        end
      end

      def test_post_with_metadata_saves_to_store
        payload = valid_payload.merge("metadata" => {
          "url" => "https://example.com/page",
          "userAgent" => "Mozilla/5.0",
          "viewport" => "1920x1080",
          "referrer" => "https://google.com"
        })

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        session = Sentiero.store.get_session("sess-1")
        assert session[:metadata], "Expected session to have metadata"
        assert_equal "https://example.com/page", session[:metadata]["url"]
        assert_equal "Mozilla/5.0", session[:metadata]["userAgent"]
      end

      def test_post_with_custom_metadata_saves_to_store
        payload = valid_payload.merge("metadata" => {
          "userId" => "user-123",
          "plan" => "pro"
        })

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        session = Sentiero.store.get_session("sess-1")
        assert session[:metadata], "Expected session to have metadata"
        assert_equal "user-123", session[:metadata]["userId"]
      end

      def test_post_without_metadata_still_works
        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        session = Sentiero.store.get_session("sess-1")
        assert_nil session[:metadata]
      end

      def test_post_with_empty_metadata_ignores_it
        payload = valid_payload.merge("metadata" => {})

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status

        session = Sentiero.store.get_session("sess-1")
        assert_nil session[:metadata]
      end

      def test_put_returns_405
        put "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 405, last_response.status
      end

      # --- has_errors detection (config.capture_errors gated) ---

      def error_event(timestamp = 5000)
        {
          "type" => 5,
          "timestamp" => timestamp,
          "data" => {"tag" => "error", "payload" => {"message" => "boom"}}
        }
      end

      def test_post_error_custom_event_sets_has_errors_metadata
        Sentiero.configuration.capture_errors = true
        payload = valid_payload.merge("events" => [
          {"type" => 3, "timestamp" => 1000},
          error_event
        ])

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        session = Sentiero.store.get_session("sess-1")
        assert session[:metadata], "Expected session metadata to be set"
        assert_equal true, session[:metadata]["has_errors"]
      end

      def test_post_without_error_events_does_not_set_has_errors
        Sentiero.configuration.capture_errors = true
        payload = valid_payload.merge("events" => [
          {"type" => 3, "timestamp" => 1000},
          {"type" => 5, "timestamp" => 2000, "data" => {"tag" => "navigation"}}
        ])

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        session = Sentiero.store.get_session("sess-1")
        if session[:metadata]
          refute session[:metadata]["has_errors"]
        end
      end

      def test_post_multiple_error_events_sets_has_errors_once
        Sentiero.configuration.capture_errors = true
        payload = valid_payload.merge("events" => [
          error_event(1000),
          error_event(2000),
          error_event(3000)
        ])

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        session = Sentiero.store.get_session("sess-1")
        assert_equal true, session[:metadata]["has_errors"]
      end

      def test_post_error_events_ignored_when_capture_errors_disabled
        Sentiero.configuration.capture_errors = false
        payload = valid_payload.merge("events" => [error_event])

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        session = Sentiero.store.get_session("sess-1")
        if session[:metadata]
          refute session[:metadata]["has_errors"]
        end
      end

      def test_post_error_events_merge_with_incoming_metadata
        Sentiero.configuration.capture_errors = true
        payload = valid_payload.merge(
          "events" => [error_event],
          "metadata" => {"url" => "https://example.com/x"}
        )

        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        session = Sentiero.store.get_session("sess-1")
        assert_equal "https://example.com/x", session[:metadata]["url"]
        assert_equal true, session[:metadata]["has_errors"]
      end

      # --- end-user opt-out (config.user_opt_out gated, defense-in-depth) ---

      def test_post_with_opt_out_disabled_stores_events_despite_cookie
        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_COOKIE" => "sentiero_optout=1"
        }

        assert_equal 200, last_response.status
        assert_equal 1, Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1")).size
      end

      def test_post_with_opt_out_enabled_and_no_cookie_stores_events
        Sentiero.configuration.user_opt_out = true

        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        assert_equal 1, Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1")).size
      end

      def test_post_with_opt_out_enabled_and_cookie_drops_events
        Sentiero.configuration.user_opt_out = true

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_COOKIE" => "sentiero_optout=1"
        }

        assert_equal 204, last_response.status
        assert_empty Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
      end

      def test_post_with_opt_out_enabled_and_custom_cookie_name_drops_events
        Sentiero.configure do |c|
          c.user_opt_out = true
          c.opt_out_cookie_name = "no_track"
        end

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_COOKIE" => "no_track=1"
        }

        assert_equal 204, last_response.status
        assert_empty Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
      end

      def test_post_opt_out_cookie_among_multiple_cookies_drops_events
        Sentiero.configuration.user_opt_out = true

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_COOKIE" => "other=val; sentiero_optout=1; another=x"
        }

        assert_equal 204, last_response.status
        assert_empty Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
      end

      # --- Global Privacy Control (config.respect_gpc gated, defense-in-depth) ---

      def test_post_with_gpc_header_and_respect_gpc_disabled_stores_events
        Sentiero.configuration.respect_gpc = false

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_SEC_GPC" => "1"
        }

        assert_equal 200, last_response.status
        assert_equal 1, Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1")).size
      end

      def test_post_with_respect_gpc_enabled_and_no_header_stores_events
        Sentiero.configuration.respect_gpc = true

        post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"}

        assert_equal 200, last_response.status
        assert_equal 1, Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1")).size
      end

      def test_post_with_gpc_header_and_respect_gpc_enabled_drops_events
        Sentiero.configuration.respect_gpc = true

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_SEC_GPC" => "1"
        }

        assert_equal 204, last_response.status
        assert_empty Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1"))
      end

      def test_post_with_gpc_header_value_other_than_1_stores_events
        Sentiero.configuration.respect_gpc = true

        post "/", JSON.generate(valid_payload), {
          "CONTENT_TYPE" => "application/json",
          "HTTP_SEC_GPC" => "0"
        }

        assert_equal 200, last_response.status
        assert_equal 1, Sentiero.store.get_events(Sentiero::WindowRef.new("sess-1", "win-1")).size
      end

      # --- geo enrichment (config.geo_source gated, server-side) ---

      def test_geo_source_cloudflare_enriches_session_metadata
        Sentiero.configuration.geo_source = :cloudflare

        post "/", JSON.generate(valid_payload),
          {"CONTENT_TYPE" => "application/json", "HTTP_CF_IPCOUNTRY" => "DE", "HTTP_CF_IPCITY" => "Berlin"}

        assert_equal 200, last_response.status
        metadata = Sentiero.store.get_session("sess-1")[:metadata]
        assert_equal "DE", metadata["geo_country"]
        assert_equal "Berlin", metadata["geo_city"]
      end

      def test_geo_disabled_by_default_stores_no_geo_keys
        post "/", JSON.generate(valid_payload.merge("metadata" => {"plan" => "pro"})),
          {"CONTENT_TYPE" => "application/json", "HTTP_CF_IPCOUNTRY" => "DE"}

        assert_equal 200, last_response.status
        metadata = Sentiero.store.get_session("sess-1")[:metadata]
        refute metadata.key?("geo_country")
      end

      def test_geo_enrichment_works_without_client_metadata
        Sentiero.configuration.geo_source = :cloudflare

        post "/", JSON.generate(valid_payload),
          {"CONTENT_TYPE" => "application/json", "HTTP_CF_IPCOUNTRY" => "PT"}

        assert_equal "PT", Sentiero.store.get_session("sess-1")[:metadata]["geo_country"]
      end

      def test_client_metadata_wins_over_server_geo_on_conflict
        Sentiero.configuration.geo_source = :cloudflare

        post "/", JSON.generate(valid_payload.merge("metadata" => {"geo_country" => "custom"})),
          {"CONTENT_TYPE" => "application/json", "HTTP_CF_IPCOUNTRY" => "DE"}

        assert_equal "custom", Sentiero.store.get_session("sess-1")[:metadata]["geo_country"]
      end

      def test_raising_geo_source_does_not_break_ingest
        Sentiero.configuration.geo_source = ->(_env) { raise "geoip db missing" }

        capture_io { post "/", JSON.generate(valid_payload), {"CONTENT_TYPE" => "application/json"} }

        assert_equal 200, last_response.status
      end

      # --- redaction engine (Sentiero::Redaction applied on every ingest) ---

      def test_redacts_navigation_url_by_default
        Sentiero.configuration.store = Sentiero::Stores::Memory.new
        nav_event = {
          "type" => 5,
          "timestamp" => 1,
          "data" => {"tag" => "navigation", "payload" => {"url" => "https://x.test/p?token=abc"}}
        }
        post_events(events: [nav_event])
        stored = Sentiero.store.get_events(window_ref).first
        assert_equal "https://x.test/p", stored["data"]["payload"]["url"]
      end

      def test_redacts_metadata_url_by_default
        Sentiero.configuration.store = Sentiero::Stores::Memory.new
        post_events(events: [dom_event], metadata: {"url" => "https://x.test/p?token=abc"})
        assert_equal "https://x.test/p", Sentiero.store.get_session(session_id)[:metadata]["url"]
      end

      def test_server_proc_fail_closed_drops_event
        Sentiero.configuration.store = Sentiero::Stores::Memory.new
        Sentiero.configuration.redaction.server_proc = ->(_e) { raise "boom" }
        capture_stderr { post_events(events: [dom_event]) }
        assert_empty Sentiero.store.get_events(window_ref)
      end

      def test_server_proc_returning_nil_drops_event
        Sentiero.configuration.store = Sentiero::Stores::Memory.new
        Sentiero.configuration.redaction.server_proc = -> {}
        post_events(events: [dom_event])
        assert_empty Sentiero.store.get_events(window_ref)
      end

      private

      def session_id = "sess-1"

      def window_ref = Sentiero::WindowRef.new("sess-1", "win-1")

      def dom_event = {"type" => 3, "timestamp" => 1000}

      def post_events(events:, metadata: nil)
        payload = {"sessionId" => session_id, "windowId" => "win-1", "events" => events}
        payload["metadata"] = metadata if metadata
        post "/", JSON.generate(payload), {"CONTENT_TYPE" => "application/json"}
      end

      def capture_stderr
        original = $stderr
        $stderr = StringIO.new
        yield
        $stderr.string
      ensure
        $stderr = original
      end

      def options(uri, body = nil, env = {})
        env = Rack::MockRequest.env_for(uri, env.merge(method: "OPTIONS", input: body))
        process_request(uri, env)
      end

      def process_request(uri, env)
        @last_response = Rack::MockResponse.new(*app.call(env))
      end

      def last_response
        @last_response || super
      end

      def gzip_compress(string)
        io = StringIO.new
        io.set_encoding("ASCII-8BIT")
        gz = Zlib::GzipWriter.new(io)
        gz.write(string)
        gz.close
        io.string
      end
    end
  end
end
