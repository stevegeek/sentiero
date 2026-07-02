# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # Request-level tests for the standalone self-contained HTML replay served at
    # /analytics/share/:id, gated by the shareable_replays config flag.
    class ShareableReplayTest < Minitest::Test
      include Rack::Test::Methods

      def app
        AnalyticsApp.new
      end

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
          c.shareable_replays = true
        end
        Manifest.reset!
        seed
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      def seed
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-1"), [
          {"type" => 4, "timestamp" => now_ms, "data" => {"width" => 1000, "height" => 800}},
          {"type" => 3, "timestamp" => now_ms + 1, "data" => {"source" => 2}}
        ])
      end

      def test_requires_auth
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/share/sess-1"

        assert_equal 403, last_response.status
      end

      def test_returns_404_when_disabled
        Sentiero.configuration.shareable_replays = false

        get "/analytics/share/sess-1"

        assert_equal 404, last_response.status
      end

      def test_returns_404_for_unknown_session
        get "/analytics/share/does-not-exist"

        assert_equal 404, last_response.status
      end

      def test_returns_400_for_invalid_id
        get "/analytics/share/bad%20id"

        assert_equal 400, last_response.status
      end

      def test_returns_200_for_known_session
        get "/analytics/share/sess-1"

        assert_equal 200, last_response.status
        assert_equal "text/html", last_response.headers["content-type"]
      end

      def test_sets_attachment_disposition_with_session_filename
        get "/analytics/share/sess-1"

        disposition = last_response.headers["content-disposition"]
        assert_includes disposition, "attachment"
        assert_includes disposition, 'filename="session-sess-1.html"'
      end

      def test_sets_nosniff_header
        get "/analytics/share/sess-1"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
      end

      def test_inlines_rrweb_player_js
        manifest = Manifest.manifest
        player_js = ::File.read(::File.join(BaseApp::ASSETS_DIR, manifest["rrweb-player"]))

        get "/analytics/share/sess-1"

        # A representative slice of the vendored bundle is inlined verbatim.
        assert_includes last_response.body, player_js[0, 200]
      end

      def test_inlines_rrweb_player_css
        manifest = Manifest.manifest
        player_css = ::File.read(::File.join(BaseApp::ASSETS_DIR, manifest["rrweb-player-css"]))

        get "/analytics/share/sess-1"

        assert_includes(last_response.body, player_css[0, 100])
      end

      def test_inlines_events_json_blob
        get "/analytics/share/sess-1"

        assert_includes last_response.body, '<script type="application/json" id="sentiero-events">'
        # The seeded event source value survives into the inline blob.
        assert_includes last_response.body, '"source":2'
      end

      def test_bootloader_initializes_player
        get "/analytics/share/sess-1"

        assert_includes last_response.body, "rrwebPlayer"
        assert_includes last_response.body, "sentiero-player"
      end

      def test_merges_events_from_all_windows
        @store.save_events(Sentiero::WindowRef.new("sess-1", "win-2"), [
          {"type" => 3, "timestamp" => now_ms + 2, "data" => {"source" => 99}}
        ])

        get "/analytics/share/sess-1"

        assert_includes last_response.body, '"source":2'
        assert_includes last_response.body, '"source":99'
      end

      # SECURITY: event data containing a literal </script> must be escaped so it
      # cannot break out of the inline JSON script block.
      def test_escapes_script_breakout_in_event_data
        @store.save_events(Sentiero::WindowRef.new("sess-evil", "win-1"), [
          {"type" => 5, "timestamp" => now_ms, "data" => {"tag" => "</script><script>alert(1)</script>"}}
        ])

        get "/analytics/share/sess-evil"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "</script><script>alert(1)"
        # The breakout must survive only in its Unicode-escaped form, proving
        # escape_json was applied to the event data (not the player's own tags).
        assert_includes last_response.body, "\\u003c/script\\u003e"
      end
    end
  end
end
