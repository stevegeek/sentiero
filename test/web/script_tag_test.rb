# frozen_string_literal: true

require "test_helper"
require "sentiero/web/script_tag"
require "json"

module Sentiero
  module Web
    class ScriptTagTest < Minitest::Test
      def setup
        Sentiero.reset_configuration!
        Sentiero.configure do |c|
          c.store = Sentiero::Stores::Memory.new
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def test_render_produces_both_script_tags
        html = ScriptTag.render(events_url: "/sentiero/events")

        assert_includes html, '<script type="application/json" id="sentiero-config">'
        assert_includes html, "<script src="
        assert_includes html, "</script>"
      end

      def test_config_json_contains_expected_keys
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal "/sentiero/events", config["eventsUrl"]
        assert_equal 10_000, config["flushIntervalMs"]
        assert_equal 50, config["flushEventThreshold"]
        assert config.key?("recorderOptions")
      end

      def test_recorder_url_defaults_to_fingerprinted_path
        html = ScriptTag.render(events_url: "/sentiero/events")

        assert_match %r{<script src="/sentiero/assets/recorder-[A-Za-z0-9]+\.js"}, html
      end

      def test_custom_recorder_url_is_used
        html = ScriptTag.render(events_url: "/sentiero/events", recorder_url: "/custom/recorder.js")

        assert_includes html, '<script src="/custom/recorder.js"></script>'
        refute_match %r{/assets/recorder-[A-Za-z0-9]+}, html
      end

      def test_script_tag_escapes_closing_script_in_events_url
        malicious_url = "https://evil.com/</script><script>alert(1)</script>"
        html = ScriptTag.render(events_url: malicious_url)

        # The literal </script> must NOT appear inside the JSON config block
        # (it would prematurely close the tag and enable XSS)
        config_tag_match = html.match(%r{<script type="application/json" id="sentiero-config">(.*?)</script>}m)
        assert config_tag_match, "Expected to find sentiero-config script tag"
        json_content = config_tag_match[1]

        refute_includes json_content, "</script>",
          "JSON config must not contain literal </script>,  XSS injection possible"

        # < is escaped to \u003c (same as Rails' ERB::Util.json_escape)
        refute_includes json_content, "<",
          "JSON config must not contain literal <,  all angle brackets should be Unicode-escaped"

        config = JSON.parse(json_content)
        assert_equal malicious_url, config["eventsUrl"]
      end

      def test_cross_tab_sessions_included_in_config
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["crossTabSessions"]
      end

      def test_cross_tab_sessions_false_when_configured
        Sentiero.configure { |c| c.cross_tab_sessions = false }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal false, config["crossTabSessions"]
      end

      def test_effective_recorder_options_are_included
        Sentiero.configure do |c|
          c.recorder_options = {customOption: "test_value"}
        end

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)
        opts = config["recorderOptions"]

        assert_equal "test_value", opts["customOption"]
        assert_equal true, opts["maskAllInputs"]
        assert_equal({"password" => true}, opts["maskInputOptions"])
      end

      def test_capture_errors_included_when_enabled
        Sentiero.configure { |c| c.capture_errors = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["captureErrors"]
      end

      def test_capture_errors_not_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("captureErrors")
      end

      def test_track_custom_events_included_when_enabled
        Sentiero.configure { |c| c.track_custom_events = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["trackCustomEvents"]
      end

      def test_track_custom_events_not_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("trackCustomEvents")
      end

      def test_capture_web_vitals_included_when_enabled
        Sentiero.configure { |c| c.capture_web_vitals = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["captureWebVitals"]
      end

      def test_capture_web_vitals_not_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("captureWebVitals")
      end

      def test_capture_clicks_included_when_enabled
        Sentiero.configure { |c| c.capture_clicks = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["captureClicks"]
      end

      def test_capture_clicks_not_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("captureClicks")
      end

      def test_track_forms_included_when_enabled
        Sentiero.configure { |c| c.track_forms = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["trackForms"]
      end

      def test_track_forms_not_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("trackForms")
      end

      def test_includes_redaction_config
        Sentiero.configuration.redaction = Sentiero::Redaction::Config.new(url_mode: :keep_filtered)
        html = ScriptTag.render(events_url: "/sentiero/events")
        json = JSON.parse(html[/id="sentiero-config">(.*?)<\/script>/m, 1])
        assert_equal "keepFiltered", json.dig("redaction", "urlMode")
      end

      def test_respect_gpc_included_by_default
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal true, config["respectGpc"]
      end

      def test_respect_gpc_omitted_when_disabled
        Sentiero.configure { |c| c.respect_gpc = false }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("respectGpc")
      end

      def test_opt_out_cookie_name_excluded_when_disabled
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        refute config.key?("optOutCookieName")
      end

      def test_opt_out_cookie_name_included_when_enabled
        Sentiero.configure { |c| c.user_opt_out = true }

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal "sentiero_optout", config["optOutCookieName"]
      end

      def test_opt_out_cookie_name_uses_configured_value
        Sentiero.configure do |c|
          c.user_opt_out = true
          c.opt_out_cookie_name = "no_track"
        end

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal "no_track", config["optOutCookieName"]
      end

      def test_session_idle_timeout_and_max_age_default_to_ms_conversion
        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal 21_600_000, config["sessionIdleTimeoutMs"]
        assert_equal 604_800_000, config["sessionMaxAgeMs"]
      end

      def test_session_idle_timeout_and_max_age_use_configured_values
        Sentiero.configure do |c|
          c.session_idle_timeout = 60
          c.session_max_age = 3600
        end

        html = ScriptTag.render(events_url: "/sentiero/events")
        config = extract_config(html)

        assert_equal 60_000, config["sessionIdleTimeoutMs"]
        assert_equal 3_600_000, config["sessionMaxAgeMs"]
      end

      private

      def extract_config(html)
        match = html.match(%r{<script type="application/json" id="sentiero-config">(.*?)</script>}m)
        assert match, "Expected to find sentiero-config script tag"
        JSON.parse(match[1])
      end
    end
  end
end
