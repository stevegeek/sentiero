# frozen_string_literal: true

require "test_helper"
require "store_contract_tests"
require "error_store_contract_tests"
require "tmpdir"

begin
  require "sqlite3"
  SQLITE_AVAILABLE = true
rescue LoadError
  SQLITE_AVAILABLE = false
end

require "sentiero/stores/sqlite" if SQLITE_AVAILABLE

module Sentiero
  module Stores
    class SQLiteTest < Minitest::Test
      include StoreContractTests
      include ErrorStoreContractTests

      def setup
        @tmpdir = Dir.mktmpdir("sentiero_sqlite_test")
        @db_path = ::File.join(@tmpdir, "test.db")
        super
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def create_store
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE
        Sentiero::Stores::SQLite.new(path: @db_path)
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

      def test_different_databases_do_not_interfere
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE

        db_a = ::File.join(@tmpdir, "a.db")
        db_b = ::File.join(@tmpdir, "b.db")

        store_a = Sentiero::Stores::SQLite.new(path: db_a)
        store_b = Sentiero::Stores::SQLite.new(path: db_b)

        store_a.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "click"}])
        store_b.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 2.0, "type" => "scroll"}])

        result_a = store_a.get_events(Sentiero::WindowRef.new("s1", "w1"))
        result_b = store_b.get_events(Sentiero::WindowRef.new("s1", "w1"))

        assert_equal 1, result_a.size
        assert_equal "click", result_a[0]["type"]

        assert_equal 1, result_b.size
        assert_equal "scroll", result_b[0]["type"]
      end

      def test_in_memory_database
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE

        store = Sentiero::Stores::SQLite.new(path: ":memory:")
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "a"}])

        result = store.get_events(Sentiero::WindowRef.new("s1", "w1"))
        assert_equal 1, result.size
      end
    end
  end
end
