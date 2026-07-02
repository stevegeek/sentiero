# frozen_string_literal: true

require "test_helper"
require "sentiero/web/analytics_app"
require "rack/test"

module Sentiero
  module Web
    # /analytics/conversions page (Plan 26): conversion rate by entry page,
    # referrer host, and UTM parameter for one selected conversion-event tag.
    class AnalyticsConversionsPageTest < Minitest::Test
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
          c.analytics_max_scan_sessions = 5000
        end
        Manifest.reset!
      end

      def teardown
        Sentiero.reset_configuration!
      end

      def now_ms
        @now_ms ||= (Time.now.to_f * 1000).round
      end

      # Seeds a session window whose FIRST event is a Meta (type 4) carrying the
      # entry href, then one custom event (type 5) per tag, plus the immutable
      # entry_url/entry_referrer metadata. save_events MUST precede save_metadata
      # (the Memory store no-ops save_metadata until the session row exists).
      def seed_session(id, entry_url:, referrer: "", tags: [], window_id: "w1", at: now_ms)
        events = [{"type" => 4, "timestamp" => at, "data" => {"href" => entry_url}}]
        tags.each_with_index do |tag, i|
          events << {"type" => 5, "timestamp" => at + (i + 1) * 100, "data" => {"tag" => tag, "payload" => {}}}
        end
        @store.save_events(Sentiero::WindowRef.new(id, window_id), events)
        @store.save_metadata(id, {"entry_url" => entry_url, "entry_referrer" => referrer})
      end

      def test_returns_200_with_heading
        get "/analytics/conversions"

        assert_equal 200, last_response.status
        assert_includes last_response.body, "Conversions"
      end

      def test_returns_403_when_auth_fails
        Sentiero.configuration.auth_callback = ->(_env) { false }

        get "/analytics/conversions"

        assert_equal 403, last_response.status
      end

      def test_sets_security_headers_and_csrf_cookie
        get "/analytics/conversions"

        assert_equal "nosniff", last_response.headers["x-content-type-options"]
        assert_equal "DENY", last_response.headers["x-frame-options"]
        assert last_response.headers["content-security-policy"]
        assert_includes last_response.headers["set-cookie"], "sentiero_csrf="
        assert_includes last_response.headers["set-cookie"], "HttpOnly"
      end

      def test_renders_tag_dropdown_from_observed_tags
        seed_session("s1", entry_url: "https://x/a", tags: %w[signup checkout])

        get "/analytics/conversions"

        body = last_response.body
        assert_includes body, 'name="tag"'
        assert_includes body, ">signup</option>"
        assert_includes body, ">checkout</option>"
      end

      def test_dropdown_excludes_internal_tags
        seed_session("s1", entry_url: "https://x/a", tags: %w[signup __perf __click error])

        get "/analytics/conversions"

        body = last_response.body
        refute_includes body, "__perf"
        refute_includes body, "__click"
        refute_includes body, ">error</option>"
      end

      def test_prompts_for_tag_when_none_selected
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])

        get "/analytics/conversions"

        assert_match(/conversion event/i, last_response.body)
      end

      def test_renders_entry_page_conversion_rate
        seed_session("s1", entry_url: "https://x/pricing", tags: %w[checkout])
        seed_session("s2", entry_url: "https://x/pricing")
        seed_session("s3", entry_url: "https://x/pricing")

        get "/analytics/conversions?tag=checkout"

        body = last_response.body
        # Pin key+sessions+conversions+rate together on the SAME entry-page row.
        # A bare substring (e.g. data-conv-rate="33.3") would also match the
        # (direct / none) referrer row, which carries identical numbers here, so
        # the assertion must bind the rate to the pricing entry-page key.
        assert_match(
          %r{data-conv-key="https://x/pricing"\s+data-conv-sessions="3"\s+data-conv-conversions="1"\s+data-conv-rate="33.3"}m,
          body
        )
      end

      def test_renders_referrer_host_row_dropping_same_origin
        seed_session("s1", entry_url: "https://x/a", referrer: "https://google.com/q", tags: %w[checkout])
        seed_session("s2", entry_url: "https://x/a", referrer: "https://x/prev")

        get "/analytics/conversions?tag=checkout"

        body = last_response.body
        assert_includes body, "google.com"
        refute_match(/data-conv-key="x"/, body)
      end

      def test_renders_utm_rows
        seed_session("s1", entry_url: "https://x/a?utm_source=google", tags: %w[checkout])

        get "/analytics/conversions?tag=checkout"

        assert_includes last_response.body, 'data-conv-key="google"'
      end

      def test_renders_replay_links
        seed_session("conv", entry_url: "https://x/p", tags: %w[checkout])
        seed_session("noconv", entry_url: "https://x/p")

        get "/analytics/conversions?tag=checkout"

        body = last_response.body
        assert_match(%r{/sessions/conv/windows/w1\?t=100}, body)
        assert_match(/converting/i, body)
      end

      def test_low_volume_note_rendered
        seed_session("s1", entry_url: "https://x/p", tags: %w[checkout])

        get "/analytics/conversions?tag=checkout"

        assert_match(/low volume/i, last_response.body)
      end

      def test_escapes_keys
        # UTM-value key carries the payload (the entry_url query stays in utm_source)...
        seed_session("s1", entry_url: "https://x/a?utm_source=<script>alert(1)</script>", tags: %w[checkout])
        # ...and the entry-page (path) key carries it too. normalize_entry strips
        # the query, so put the payload in the PATH to reach a data-conv-key on an
        # entry-page row, not just a UTM-source row.
        seed_session("s2", entry_url: "https://x/<script>alert(1)</script>", tags: %w[checkout])

        get "/analytics/conversions?tag=checkout"

        body = last_response.body
        refute_includes body, "<script>alert(1)</script>"
        assert_includes body, "&lt;script&gt;"
      end

      def test_truncation_warning_when_capped
        @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 1)
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])
        seed_session("s2", entry_url: "https://x/b", tags: %w[checkout])

        get "/analytics/conversions?tag=checkout"

        assert_equal 200, last_response.status
        assert_match(/truncat|capp|incomplete/i, last_response.body)
      end

      def test_renders_from_to_date_inputs
        get "/analytics/conversions"

        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_honors_date_range
        seed_session("s1", entry_url: "https://x/p", tags: %w[checkout])
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/analytics/conversions?tag=checkout&until=#{yesterday}"
        refute_includes last_response.body, 'data-conv-key="https://x/p"'

        get "/analytics/conversions?tag=checkout&since=#{today}&until=#{today}"
        assert_includes last_response.body, 'data-conv-key="https://x/p"'
      end

      def test_form_reflects_selected_tag
        seed_session("s1", entry_url: "https://x/a", tags: %w[checkout])

        get "/analytics/conversions?tag=checkout"

        assert_match(/<option[^>]*value="checkout"[^>]*selected/, last_response.body)
      end

      def test_renders_sub_navigation
        get "/analytics/conversions"

        assert_includes last_response.body, "/analytics/funnel"
        assert_includes last_response.body, "/analytics/export"
      end
    end
  end
end
