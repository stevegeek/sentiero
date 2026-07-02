# frozen_string_literal: true

require "test_helper"
require "store_contract_tests"
require "error_store_contract_tests"
require "tmpdir"
require "sentiero/stores/file"

module Sentiero
  module Stores
    class FileTest < Minitest::Test
      include StoreContractTests
      include ErrorStoreContractTests

      def setup
        @tmpdir = Dir.mktmpdir("sentiero_file_test")
        super
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def create_store
        Sentiero::Stores::File.new(path: @tmpdir)
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

      def test_different_paths_do_not_interfere
        dir_a = Dir.mktmpdir("sentiero_file_a")
        dir_b = Dir.mktmpdir("sentiero_file_b")

        store_a = Sentiero::Stores::File.new(path: dir_a)
        store_b = Sentiero::Stores::File.new(path: dir_b)

        store_a.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "click"}])
        store_b.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 2.0, "type" => "scroll"}])

        result_a = store_a.get_events(Sentiero::WindowRef.new("s1", "w1"))
        result_b = store_b.get_events(Sentiero::WindowRef.new("s1", "w1"))

        assert_equal 1, result_a.size
        assert_equal "click", result_a[0]["type"]

        assert_equal 1, result_b.size
        assert_equal "scroll", result_b[0]["type"]
      ensure
        FileUtils.rm_rf(dir_a) if dir_a
        FileUtils.rm_rf(dir_b) if dir_b
      end

      def test_persists_across_store_instances
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "a"}])

        store2 = Sentiero::Stores::File.new(path: @tmpdir)
        result = store2.get_events(Sentiero::WindowRef.new("s1", "w1"))

        assert_equal 1, result.size
        assert_equal "a", result[0]["type"]
      end
    end
  end
end
