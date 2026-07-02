# frozen_string_literal: true

require "test_helper"
require "sentiero/analytics/browser_event_discovery"

module Sentiero
  module Analytics
    class BrowserEventDiscoveryTest < Minitest::Test
      def setup
        @store = Stores::Memory.new
        Sentiero.configure { |c| c.store = @store }
      end

      def teardown = Sentiero.reset_configuration!

      def save_window(sid, wid, events)
        @store.save_events(Sentiero::WindowRef.new(sid, wid), events)
      end

      def custom(tag, ts, payload = {})
        {"type" => 5, "timestamp" => ts, "data" => {"tag" => tag, "payload" => payload}}
      end

      def test_collects_non_error_custom_events_newest_first
        save_window("s1", "w1", [
          {"type" => 3, "timestamp" => 100.0}, # not custom — ignored
          custom("add_to_cart", 150.0, {"sku" => "ABC"}),
          custom("error", 160.0, {"payload" => {"message" => "boom"}}), # error tag — excluded
          custom("checkout", 170.0)
        ])
        rows = BrowserEventDiscovery.new(@store).recent_events[:rows]
        names = rows.map { |r| r[:name] }
        assert_equal ["checkout", "add_to_cart"], names # newest first, error excluded
        cart = rows.find { |r| r[:name] == "add_to_cart" }
        assert_equal "s1", cart[:session_id]
        assert_equal "w1", cart[:window_id]
        assert_equal({"sku" => "ABC"}, cart[:payload])
        assert_kind_of Integer, cart[:offset_ms]
      end

      def test_empty_when_no_custom_events
        save_window("s2", "w2", [{"type" => 3, "timestamp" => 1.0}])
        assert_empty BrowserEventDiscovery.new(@store).recent_events[:rows]
      end

      def test_caps_rows_and_flags_truncation_beyond_max_rows
        # Enough events across sessions to exceed the mid-scan accumulation limit,
        # exercising the periodic sort+trim path as well as the final cap.
        total = BrowserEventDiscovery::ACCUMULATION_LIMIT + BrowserEventDiscovery::MAX_ROWS + 50
        per_session = 600
        ts = 0.0
        session = 0
        while ts < total
          events = [{"type" => 3, "timestamp" => ts}]
          per_session.times do
            ts += 1.0
            events << custom("evt_#{ts.to_i}", ts)
          end
          save_window("trunc_s#{session}", "trunc_w#{session}", events)
          session += 1
        end

        result = BrowserEventDiscovery.new(@store).recent_events
        assert_equal BrowserEventDiscovery::MAX_ROWS, result[:rows].size
        assert result[:was_truncated]
        # The globally-newest events survive the mid-scan trims.
        timestamps = result[:rows].map { |r| r[:timestamp] }
        assert_equal timestamps.sort.reverse, timestamps # newest first
        assert_equal ts, timestamps.first # the very last event saved is retained
      end

      # ── since/until_time bounds ──

      def test_recent_events_honors_date_bounds
        save_window("s1", "w1", [custom("add_to_cart", 150.0)])

        out_of_window = BrowserEventDiscovery.new(@store)
          .recent_events(until_time: Time.now.to_f - 3600)[:rows]
        in_window = BrowserEventDiscovery.new(@store)
          .recent_events(since: Time.now.to_f - 3600, until_time: Time.now.to_f + 3600)[:rows]

        assert_empty out_of_window
        assert_equal ["add_to_cart"], in_window.map { |r| r[:name] }
      end
    end
  end
end
