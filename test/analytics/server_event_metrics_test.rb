# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/server_event_metrics"

module Sentiero
  module Analytics
    class ServerEventMetricsTest < Minitest::Test
      def event(name:, level: "info", at: Time.now.to_f, payload: nil)
        e = {"name" => name, "level" => level, "timestamp" => at}
        e["payload"] = payload if payload
        e
      end

      # ── level_mix_by_day ──

      def test_level_mix_buckets_by_utc_day_and_defaults_unknown_level_to_info
        today = Time.now.utc.to_date.to_s
        events = [
          event(name: "a", level: "error"),
          event(name: "b", level: "weird"), # unknown -> info
          event(name: "c", level: "info")
        ]
        mix = ServerEventMetrics.new(events).level_mix_by_day
        date, counts = mix.last
        assert_equal today, date
        assert_equal 1, counts["error"]
        assert_equal 2, counts["info"]
      end

      def test_level_mix_skips_events_without_timestamp
        assert_empty ServerEventMetrics.new([event(name: "a", at: 0)]).level_mix_by_day
      end

      # ── payload_metric_locals ──

      def test_no_metrics_when_event_names_differ
        events = [event(name: "a", payload: {"amt" => 1.0}), event(name: "b", payload: {"amt" => 2.0})]
        locals = ServerEventMetrics.new(events).payload_metric_locals("amt")
        assert_nil locals[:single_name]
        assert_empty locals[:metric_keys]
        assert_nil locals[:metric_key]
      end

      def test_offers_only_numeric_keys_for_single_name
        events = [
          event(name: "order", payload: {"amount" => 49.0, "currency" => "usd"}),
          event(name: "order", payload: {"amount" => 51.0, "currency" => "usd"})
        ]
        locals = ServerEventMetrics.new(events).payload_metric_locals("amount")
        assert_equal "order", locals[:single_name]
        assert_equal ["amount"], locals[:metric_keys]
        assert_equal "amount", locals[:metric_key]
      end

      def test_unknown_requested_key_yields_no_metric_days
        events = [event(name: "order", payload: {"amount" => 1.0})]
        locals = ServerEventMetrics.new(events).payload_metric_locals("currency")
        assert_nil locals[:metric_key]
        assert_empty locals[:metric_days]
      end

      def test_metric_days_compute_per_day_math_and_count_non_numeric
        today = Time.now.utc.to_date.to_s
        events = [
          event(name: "order", payload: {"amount" => 49.0}),
          event(name: "order", payload: {"amount" => 51.0}),
          event(name: "order", payload: {"amount" => "n/a"})
        ]
        days = ServerEventMetrics.new(events).payload_metric_locals("amount")[:metric_days]
        date, m = days.last
        assert_equal today, date
        assert_equal 2, m[:count]
        assert_in_delta 100.0, m[:sum]
        assert_in_delta 49.0, m[:min]
        assert_in_delta 51.0, m[:max]
        assert_equal 1, m[:non_numeric]
      end

      # ── adapt_browser_rows ──

      def test_adapt_browser_rows_converts_ms_to_seconds_and_string_keys
        rows = [{name: "plan_selected", payload: {"price" => 29.0}, timestamp: 11_000}]
        adapted = ServerEventMetrics.adapt_browser_rows(rows)
        assert_equal "plan_selected", adapted.first["name"]
        assert_in_delta 11.0, adapted.first["timestamp"]
        assert_equal({"price" => 29.0}, adapted.first["payload"])
      end
    end
  end
end
