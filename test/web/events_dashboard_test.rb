# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"
require "rack/test"

module Sentiero
  module Web
    class EventsDashboardTest < Minitest::Test
      include Rack::Test::Methods

      def app = DashboardApp.new

      def setup
        @store = Stores::Memory.new
        Sentiero.configure do |c|
          c.allow_insecure_dashboard = true
          c.store = @store
          c.auth_callback = nil
        end
        Manifest.reset!
        @store.save_server_event("project" => "app", "name" => "signup", "level" => "info", "session_id" => "sess_1", "timestamp" => 1000.0)
        @store.save_server_event("project" => "other", "name" => "payment_failed", "level" => "error", "timestamp" => 2000.0)
      end

      def teardown = Sentiero.reset_configuration!

      def test_events_index_lists_all_projects_events
        get "/custom-events"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "signup"
        assert_includes last_response.body, "payment_failed"
      end

      def test_events_index_filters_by_level
        get "/custom-events?level=error"
        assert_includes last_response.body, "payment_failed"
        refute_includes last_response.body, "signup"
      end

      def test_events_index_filters_by_name_search
        get "/custom-events?search=sign"
        assert_includes last_response.body, "signup"
        refute_includes last_response.body, "payment_failed"
      end

      def test_events_index_forbidden_without_auth
        Sentiero.configuration.auth_callback = ->(_e) { false }
        get "/custom-events"
        assert_equal 403, last_response.status
      end

      # ── server-events date range ──

      def test_events_index_filter_has_date_inputs
        get "/custom-events"
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_events_index_honors_date_range
        # Seeded events are from 1970 (timestamps 1000.0/2000.0); add a fresh one.
        @store.save_server_event("project" => "app", "name" => "fresh_event",
          "level" => "info", "timestamp" => Time.now.to_f)
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/custom-events?until=#{yesterday}"
        assert_includes last_response.body, "signup"
        refute_includes last_response.body, "fresh_event"

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        get "/custom-events?since=#{today}&until=#{today}"
        assert_includes last_response.body, "fresh_event"
        refute_includes last_response.body, "signup"
      end

      def test_events_index_pagination_preserves_date_range
        @store.save_server_event("project" => "app", "name" => "fresh_event",
          "level" => "info", "timestamp" => Time.now.to_f)
        today = Time.now.utc.to_date.to_s

        get "/custom-events?per_page=1&since=#{today}&until=#{today}"

        assert_includes last_response.body, "since=#{today}"
        assert_includes last_response.body, "until=#{today}"
      end

      # ── B7: per-day level-mix strip over the already-fetched events ──

      def test_events_index_renders_level_mix_strip
        @store.save_server_event("project" => "app", "name" => "ok_event",
          "level" => "info", "timestamp" => Time.now.to_f)
        @store.save_server_event("project" => "app", "name" => "bad_event",
          "level" => "error", "timestamp" => Time.now.to_f)
        today = Time.now.utc.to_date.to_s

        get "/custom-events"

        body = last_response.body
        assert_match(/level mix/i, body)
        assert_includes body, %(data-level-day="#{today}")
        assert_includes body, 'data-level-seg="info"'
        assert_includes body, 'data-level-seg="error"'
      end

      def test_level_mix_error_segment_links_to_day_with_level_filter
        @store.save_server_event("project" => "app", "name" => "bad_event",
          "level" => "error", "timestamp" => Time.now.to_f)
        today = Time.now.utc.to_date.to_s

        get "/custom-events"

        assert_includes last_response.body, "level=error"
        assert_includes last_response.body, "since=#{today}&amp;until=#{today}"
      end

      def test_level_mix_error_link_carries_current_filters
        @store.save_server_event("project" => "app", "name" => "bad_event",
          "level" => "error", "timestamp" => Time.now.to_f)

        get "/custom-events?search=bad"

        assert_includes last_response.body, "level=error&amp;search=bad&amp;since="
      end

      def test_level_mix_strip_honors_active_level_filter
        @store.save_server_event("project" => "app", "name" => "quiet_event",
          "level" => "info", "timestamp" => Time.now.to_f)

        get "/custom-events?level=error"

        body = last_response.body
        # Only the (seeded) error event remains after the filter; no info segment.
        assert_includes body, 'data-level-seg="error"'
        refute_includes body, 'data-level-seg="info"'
      end

      def test_level_mix_absent_on_browser_tab
        get "/custom-events?source=browser"

        refute_match(/level mix/i, last_response.body)
      end

      # ── C5(b): per-day volume strip when a name filter is active ──

      def seed_named_event(name, at:, payload: nil)
        event = {"project" => "app", "name" => name, "level" => "info", "timestamp" => at}
        event["payload"] = payload if payload
        @store.save_server_event(event)
      end

      def test_filtered_events_render_volume_scaled_day_strip
        today = Time.now.to_f
        2.times { seed_named_event("order_completed", at: today) }
        seed_named_event("order_completed", at: today - 86_400)
        seed_named_event("unrelated_noise", at: today)

        get "/custom-events?search=order_completed"

        body = last_response.body
        # Bars scale to the busiest day: today 2/2 -> 100%, yesterday 1/2 -> 50%.
        assert_includes body, 'data-volume-pct="100.0"'
        assert_includes body, 'data-volume-pct="50.0"'
      end

      def test_volume_scaling_absent_without_search_filter
        seed_named_event("order_completed", at: Time.now.to_f)

        get "/custom-events"

        # Unfiltered, the strip stays a full-width level mix per day.
        refute_includes last_response.body, "data-volume-pct"
        assert_includes last_response.body, 'data-level-day="'
      end

      # ── C5(c): numeric payload metrics for a single event name ──

      def seed_order_events
        today = Time.now.to_f
        seed_named_event("order_completed", at: today, payload: {"amount" => 49.0, "currency" => "usd"})
        seed_named_event("order_completed", at: today, payload: {"amount" => 51.0, "currency" => "usd"})
        seed_named_event("order_completed", at: today, payload: {"amount" => "n/a"})
      end

      def test_metric_key_select_offered_when_single_name_filtered
        seed_order_events

        get "/custom-events?search=order_completed"

        body = last_response.body
        assert_includes body, 'name="metric_key"'
        # Only keys with at least one numeric value are offered.
        assert_includes body, ">amount</option>"
        refute_includes body, ">currency</option>"
      end

      def test_metric_key_select_absent_when_multiple_names_match
        seed_order_events
        seed_named_event("order_refunded", at: Time.now.to_f, payload: {"amount" => 10.0})

        get "/custom-events?search=order"

        refute_includes last_response.body, 'name="metric_key"'
      end

      def test_payload_metrics_table_renders_per_day_math
        seed_order_events
        today = Time.now.utc.to_date.to_s

        get "/custom-events?search=order_completed&metric_key=amount"

        body = last_response.body
        assert_includes body, %(data-metric-day="#{today}")
        assert_includes body, 'data-metric-count="2"'
        assert_includes body, 'data-metric-sum="100.0"'
        assert_includes body, 'data-metric-avg="50.0"'
        assert_includes body, 'data-metric-min="49.0"'
        assert_includes body, 'data-metric-max="51.0"'
        # The non-numeric "n/a" amount is skipped and counted separately.
        assert_match(/1 non-numeric/i, body)
      end

      def test_payload_metrics_ignore_unknown_metric_key
        seed_order_events

        get "/custom-events?search=order_completed&metric_key=currency"

        assert_equal 200, last_response.status
        refute_includes last_response.body, "data-metric-day"
      end

      def test_payload_metrics_honor_active_date_range
        seed_order_events
        yesterday = (Time.now.utc.to_date - 1).to_s
        seed_named_event("order_completed", at: Time.parse("#{yesterday} 12:00 UTC").to_f,
          payload: {"amount" => 200.0})

        get "/custom-events?search=order_completed&metric_key=amount&since=#{yesterday}&until=#{yesterday}"

        body = last_response.body
        assert_includes body, %(data-metric-day="#{yesterday}")
        assert_includes body, 'data-metric-sum="200.0"'
        refute_includes body, 'data-metric-sum="100.0"'
      end

      def test_level_mix_absent_without_events
        @store = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store
          c.auth_callback = nil
        }

        get "/custom-events"

        refute_match(/level mix/i, last_response.body)
      end

      def test_events_index_links_session
        get "/custom-events"
        assert_includes last_response.body, "/sessions/sess_1"
      end

      def test_events_list_renders_payload_preview
        @store.save_server_event("project" => "app", "name" => "paid", "level" => "info",
          "payload" => {"amount" => 4999, "currency" => "usd"}, "timestamp" => 1000.0)
        get "/custom-events"
        assert_includes last_response.body, "amount"   # payload key surfaced
        assert_includes last_response.body, "4999"
      end

      def test_event_show_renders_full_payload
        @store.save_server_event("project" => "app", "name" => "paid", "level" => "warn",
          "payload" => {"amount" => 4999}, "session_id" => "s_ev", "timestamp" => 1000.0)
        id = @store.list_server_events(project: "app", limit: 10).find { |e| e["name"] == "paid" }["id"]
        get "/custom-events/#{id}"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "paid"
        assert_includes last_response.body, "4999"
        assert_includes last_response.body, "s_ev"
      end

      def test_event_show_404_for_unknown
        get "/custom-events/does-not-exist"
        assert_equal 404, last_response.status
      end

      def test_event_list_links_to_detail
        @store.save_server_event("project" => "app", "name" => "ev1", "level" => "info", "timestamp" => 1.0)
        id = @store.list_server_events(project: "app", limit: 10).find { |e| e["name"] == "ev1" }["id"]
        get "/custom-events"
        assert_includes last_response.body, "/custom-events/#{id}"
      end

      def test_events_filter_by_project
        @store.save_server_event("project" => "app", "name" => "a_ev", "level" => "info", "timestamp" => 1.0)
        @store.save_server_event("project" => "other", "name" => "b_ev", "level" => "info", "timestamp" => 2.0)
        get "/custom-events?project=other"
        assert_includes last_response.body, "b_ev"
        refute_includes last_response.body, "a_ev"
      end

      # Task 1: pagination on events list
      def test_events_index_pagination_page1_shows_cap_and_next_link
        # Setup has 2 events; add a 3rd so with per_page=2 we get Next
        @store.save_server_event("project" => "app", "name" => "ev_extra", "level" => "info", "timestamp" => 3000.0)
        get "/custom-events?per_page=2&page=1"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "page=2"
        assert_includes body, "Next"
      end

      def test_events_index_pagination_page2_shows_remaining
        @store.save_server_event("project" => "app", "name" => "ev_extra2", "level" => "info", "timestamp" => 4000.0)
        get "/custom-events?per_page=2&page=2"
        assert_equal 200, last_response.status
        refute_includes last_response.body, "No events recorded yet"
      end

      # Task 4: filter-aware empty state on events
      def test_events_index_filter_aware_empty_state
        get "/custom-events?search=zzzznomatch"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "Clear filters"
        refute_includes last_response.body, "No events recorded yet"
      end

      # Task 4: source tabs + browser events
      def test_events_index_has_source_tabs
        get "/custom-events"
        body = last_response.body
        assert_includes body, "Server events"
        assert_includes body, "Browser events"
        assert_includes body, "/custom-events?source=browser"
      end

      def test_browser_events_tab_lists_rrweb_custom_events
        @store.save_events(Sentiero::WindowRef.new("sess_be", "win_be"), [
          {"type" => 3, "timestamp" => 100.0},
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "signup", "payload" => {"plan" => "pro"}}}
        ])
        get "/custom-events?source=browser"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "signup"
        # replay deep-link with ?t= offset
        assert_includes body, "/sessions/sess_be/windows/win_be?t="
      end

      def test_browser_events_tab_filters_by_search
        @store.save_events(Sentiero::WindowRef.new("sess_be_s", "win_s"), [
          {"type" => 3, "timestamp" => 100.0},
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "checkout_started"}},
          {"type" => 5, "timestamp" => 160.0, "data" => {"tag" => "page_view"}}
        ])
        get "/custom-events?source=browser&search=checkout"
        assert_equal 200, last_response.status
        body = last_response.body
        assert_includes body, "checkout_started"
        refute_includes body, "page_view"
      end

      def test_browser_events_tab_excludes_error_tag
        @store.save_events(Sentiero::WindowRef.new("sess_be2", "win_be2"), [
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "error", "payload" => {"message" => "boom"}}}
        ])
        get "/custom-events?source=browser"
        refute_includes last_response.body, "boom"
      end

      def test_events_index_bare_empty_state_without_filters
        @store = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store
          c.auth_callback = nil
        }
        get "/custom-events"
        assert_equal 200, last_response.status
        assert_includes last_response.body, "No events recorded yet"
        refute_includes last_response.body, "Clear filters"
      end

      # ── C3 (P2.3): empty tabs cross-reference the populated sibling ──

      def reset_store!
        @store = Stores::Memory.new
        Sentiero.configure { |c|
          c.store = @store
          c.auth_callback = nil
        }
      end

      def test_empty_server_events_tab_cross_references_browser_events
        reset_store!
        @store.save_events(Sentiero::WindowRef.new("sess_cb", "w1"), [
          {"type" => 3, "timestamp" => 100.0},
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "cta_clicked"}},
          {"type" => 5, "timestamp" => 160.0, "data" => {"tag" => "plan_selected"}}
        ])

        get "/custom-events"

        body = last_response.body
        assert_includes body, "No events recorded yet"
        assert_includes body, 'data-sibling-count="2"'
        assert_includes body, "2 browser events"
        assert_includes body, "/custom-events?source=browser"
      end

      def test_empty_browser_tab_cross_references_server_events
        # setup seeded two server events; no browser custom events exist.
        get "/custom-events?source=browser"

        body = last_response.body
        assert_includes body, "No browser events captured yet"
        assert_includes body, 'data-sibling-count="2"'
        assert_includes body, "2 server events"
      end

      def test_empty_tabs_without_sibling_rows_have_no_cross_reference
        reset_store!

        get "/custom-events"
        refute_includes last_response.body, "data-sibling-count"

        get "/custom-events?source=browser"
        refute_includes last_response.body, "data-sibling-count"
      end

      def test_filtered_empty_browser_tab_has_no_cross_reference
        get "/custom-events?source=browser&search=zzzznomatch"

        refute_includes last_response.body, "data-sibling-count"
      end

      # ── Phase 3: redesign (shared partials / tabs / browser filter) ──
      def test_events_index_uses_underline_tab_classes
        get "/custom-events"
        body = last_response.body
        assert_includes body, 'class="tab '
        assert_includes body, "tab-active"
        refute_includes body, "btn-active"
      end

      def test_events_index_server_uses_badge_danger_not_error
        get "/custom-events?level=error"
        body = last_response.body
        assert_includes body, "badge-danger"
        refute_includes body, "badge-error"
      end

      def test_browser_events_tab_has_filter_bar_with_hidden_source
        @store.save_events(Sentiero::WindowRef.new("sess_bf", "win_bf"), [
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "signup"}}
        ])
        get "/custom-events?source=browser"
        body = last_response.body
        assert_includes body, 'name="search"'
        assert_includes body, 'name="source"'
        assert_includes body, 'value="browser"'
      end

      def test_browser_events_tab_has_time_column
        @store.save_events(Sentiero::WindowRef.new("sess_tc", "win_tc"), [
          {"type" => 3, "timestamp" => 100.0},
          {"type" => 5, "timestamp" => 150.0, "data" => {"tag" => "signup"}}
        ])
        get "/custom-events?source=browser"
        body = last_response.body
        assert_includes body, "<th class=\"w-24\">Time</th>"
      end

      # ── C1: payload metrics on the browser-events tab ──

      # Mirrors the product-review ground truth: plan_selected fired twice
      # (price 29.0 and 79.0) across two sessions -> n=2, sum=108, avg=54.
      def seed_browser_plan_events
        now_ms = (Time.now.to_f * 1000).round
        @store.save_events(Sentiero::WindowRef.new("sess_pm1", "win_pm1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 100,
           "data" => {"tag" => "plan_selected", "payload" => {"plan" => "pro", "price" => 29.0}}}
        ])
        @store.save_events(Sentiero::WindowRef.new("sess_pm2", "win_pm2"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 200,
           "data" => {"tag" => "plan_selected", "payload" => {"plan" => "team", "price" => 79.0}}},
          {"type" => 5, "timestamp" => now_ms + 300, "data" => {"tag" => "todo_created"}}
        ])
      end

      def test_browser_metric_key_select_offered_when_single_name_filtered
        seed_browser_plan_events

        get "/custom-events?source=browser&search=plan_selected"

        body = last_response.body
        assert_includes body, 'name="metric_key"'
        # Only keys with at least one numeric value are offered.
        assert_includes body, ">price</option>"
        refute_includes body, ">plan</option>"
      end

      def test_browser_metric_key_select_absent_when_multiple_names_match
        seed_browser_plan_events

        get "/custom-events?source=browser"

        refute_includes last_response.body, 'name="metric_key"'
      end

      def test_browser_payload_metrics_render_ground_truth_numbers
        seed_browser_plan_events
        today = Time.now.utc.to_date.to_s

        get "/custom-events?source=browser&search=plan_selected&metric_key=price"

        body = last_response.body
        assert_includes body, %(data-metric-day="#{today}")
        assert_includes body, 'data-metric-count="2"'
        assert_includes body, 'data-metric-sum="108.0"'
        assert_includes body, 'data-metric-avg="54.0"'
        assert_includes body, 'data-metric-min="29.0"'
        assert_includes body, 'data-metric-max="79.0"'
      end

      def test_browser_payload_metrics_form_stays_on_browser_tab
        seed_browser_plan_events

        get "/custom-events?source=browser&search=plan_selected"

        metrics_form = last_response.body[%r{<form method="get"[^>]*>(?:(?!</form>).)*metric_key.*?</form>}m]
        refute_nil metrics_form, "expected a metric-key form on the browser tab"
        assert_includes metrics_form, 'name="source"'
        assert_includes metrics_form, 'value="browser"'
        assert_includes metrics_form, 'value="plan_selected"'
      end

      # ── date range on the browser-events tab ──

      def test_browser_events_tab_has_date_inputs
        get "/custom-events?source=browser"
        assert_includes last_response.body, 'name="since"'
        assert_includes last_response.body, 'name="until"'
      end

      def test_browser_events_tab_honors_date_range
        now_ms = (Time.now.to_f * 1000).round
        @store.save_events(Sentiero::WindowRef.new("sess_dr", "win_dr"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 50, "data" => {"tag" => "cart_add"}}
        ])
        yesterday = (Time.now.utc.to_date - 1).to_s
        today = Time.now.utc.to_date.to_s

        get "/custom-events?source=browser&until=#{yesterday}"
        refute_includes last_response.body, "cart_add"

        # The To-day is inclusive (regression: until=<today> used to cut at 00:00).
        get "/custom-events?source=browser&since=#{today}&until=#{today}"
        assert_includes last_response.body, "cart_add"
      end
    end
  end
end
