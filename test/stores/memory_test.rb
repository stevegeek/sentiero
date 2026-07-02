# frozen_string_literal: true

require "test_helper"
require "store_contract_tests"
require "error_store_contract_tests"

module Sentiero
  module Stores
    class MemoryTest < Minitest::Test
      include StoreContractTests
      include ErrorStoreContractTests

      def create_store
        Sentiero::Stores::Memory.new
      end

      def test_clear_removes_all_sessions_and_events
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "a"}])
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"timestamp" => 2.0, "type" => "b"}])

        @store.clear!

        assert_equal [], @store.list_sessions(limit: 10)
        assert_nil @store.get_session("s1")
        assert_nil @store.get_session("s2")
        assert_equal [], @store.get_events(Sentiero::WindowRef.new("s1", "w1"))
        assert_equal [], @store.get_events(Sentiero::WindowRef.new("s2", "w1"))
      end

      def test_clear_allows_new_data_after_clearing
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "a"}])
        @store.clear!
        @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [{"timestamp" => 2.0, "type" => "b"}])

        assert_equal 1, @store.list_sessions(limit: 10).size
        assert_equal "s2", @store.list_sessions(limit: 10).first[:session_id]
      end

      def test_max_problems_evicts_least_recently_seen
        @store.limits = Sentiero::Store::Limits.new(max_problems: 2)
        @store.save_occurrence(make_occurrence(fingerprint: "fp_x", timestamp: 1.0))
        @store.save_occurrence(make_occurrence(fingerprint: "fp_y", timestamp: 2.0))
        @store.save_occurrence(make_occurrence(fingerprint: "fp_z", timestamp: 3.0))

        ids = @store.list_problems(project: "app", limit: 10).map { |p| p[:id] }
        refute_includes ids, "fp_x"
        assert_includes ids, "fp_y"
        assert_includes ids, "fp_z"
        assert_equal [], @store.get_occurrences("fp_x")
      end

      def test_max_server_events_drops_oldest
        @store.limits = Sentiero::Store::Limits.new(max_server_events: 2)
        @store.save_server_event(make_server_event(name: "a", timestamp: 1.0))
        @store.save_server_event(make_server_event(name: "b", timestamp: 2.0))
        @store.save_server_event(make_server_event(name: "c", timestamp: 3.0))

        names = @store.list_server_events(project: "app", limit: 10).map { |e| e["name"] }
        assert_equal %w[b c], names
      end
    end
  end
end
