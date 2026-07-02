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
