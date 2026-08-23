# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/exporter"

module Sentiero
  module Analytics
    class ExporterTest < Minitest::Test
      def setup
        @store = Sentiero::Stores::Memory.new
        @exporter = Exporter.new(@store)
      end

      # Regression: a problem's fingerprint is exposed as :id, so the exported
      # fingerprint column was always blank when it read a nonexistent :fingerprint.
      def test_problems_export_populates_the_fingerprint_column
        @store.save_occurrence({
          "fingerprint" => "fp-abc",
          "project" => "web",
          "exception_class" => "ArgumentError",
          "message" => "boom",
          "timestamp" => Time.now.to_f
        })

        table = @exporter.table("problems")
        fp_index = table[:headers].index("fingerprint")
        assert_equal "fp-abc", table[:rows].first[fp_index]
      end

      def test_errors_export_includes_resolved_and_ignored_groups
        now_ms = (Time.now.to_f * 1000).round
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"type" => 3, "timestamp" => now_ms},
          {"type" => 5, "timestamp" => now_ms + 100, "data" => {"tag" => "error", "payload" => {"message" => "Fixed boom"}}},
          {"type" => 5, "timestamp" => now_ms + 200, "data" => {"tag" => "error", "payload" => {"message" => "Noisy boom"}}}
        ])
        Sentiero.configure { |c| c.store = @store }
        groups = ErrorDiscovery.new(@store).grouped_errors[:groups]
        fixed = groups.find { |g| g[:message] == "Fixed boom" }[:id]
        noisy = groups.find { |g| g[:message] == "Noisy boom" }[:id]
        @store.set_client_error_state(fixed, status: "resolved", changed_at: Time.now.to_f, last_seen_at: now_ms + 100)
        @store.set_client_error_state(noisy, status: "ignored", changed_at: Time.now.to_f, last_seen_at: now_ms + 200)

        table = @exporter.table("errors")
        messages = table[:rows].map(&:first)
        assert_includes messages, "Fixed boom"
        assert_includes messages, "Noisy boom"
      ensure
        Sentiero.reset_configuration!
      end

      # Regression: `since` is inclusive for every dataset; server_events used the
      # store's exclusive `after` cursor and dropped an event exactly at `since`.
      def test_server_events_export_since_bound_is_inclusive
        at = 1_000.0
        @store.save_server_event({
          "project" => "api", "name" => "signup", "level" => "info", "timestamp" => at
        })

        table = @exporter.table("server_events", since: at)
        assert_equal 1, table[:rows].size, "event exactly at `since` must be included"
      end
    end
  end
end
