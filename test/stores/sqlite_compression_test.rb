# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "zlib"

begin
  require "sqlite3"
rescue LoadError
end

require "sentiero/stores/sqlite" if defined?(::SQLite3)

module Sentiero
  module Stores
    class SQLiteCompressionTest < Minitest::Test
      include SQLiteStoreTracking

      def setup
        skip "sqlite3 gem not available" unless defined?(::SQLite3)
        @tmpdir = Dir.mktmpdir("sentiero_sqlite_compression_test")
        @db_path = ::File.join(@tmpdir, "test.db")
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def store
        @store ||= open_sqlite_store(path: @db_path)
      end

      def raw_db
        db = ::SQLite3::Database.new(@db_path)
        db.results_as_hash = true
        yield db
      ensure
        db&.close
      end

      # A realistic FullSnapshot-ish payload: repetitive DOM-ish JSON, well
      # over the compression threshold.
      def big_event(timestamp: 1.0)
        node = {"tag" => "div", "attributes" => {"class" => "menu-item card"}, "text" => "Pizza Margherita con mozzarella"}
        {"type" => 2, "timestamp" => timestamp, "data" => {"node" => Array.new(200) { node }}}
      end

      def small_event(timestamp: 1.0)
        {"type" => 3, "timestamp" => timestamp, "data" => {"source" => 1, "x" => 10, "y" => 20}}
      end

      def test_large_payloads_are_stored_compressed_and_round_trip
        event = big_event
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [event])

        raw_db do |db|
          row = db.get_first_row("SELECT typeof(data) AS t, LENGTH(data) AS len FROM events")
          assert_equal "blob", row["t"], "large payload should be stored as a compressed blob"
          assert_operator row["len"], :<, JSON.generate(event).bytesize / 2,
            "stored blob should be substantially smaller than the raw JSON"
        end

        assert_equal [event], store.get_events(Sentiero::WindowRef.new("s1", "w1"))
      end

      def test_small_payloads_are_stored_as_plain_text
        event = small_event
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [event])

        raw_db do |db|
          assert_equal "text", db.get_first_value("SELECT typeof(data) FROM events"),
            "sub-threshold payloads should stay plain JSON text"
        end

        assert_equal [event], store.get_events(Sentiero::WindowRef.new("s1", "w1"))
      end

      def test_each_session_events_decodes_compressed_payloads
        big = big_event(timestamp: 1.0)
        small = small_event(timestamp: 2.0)
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [big, small])

        captured = nil
        store.each_session_events { |_session, _window_id, events| captured = events }
        assert_equal [big, small], captured
      end

      def test_unicode_payloads_round_trip_through_compression
        event = big_event
        event["data"]["note"] = "Menù dell'estate — 🍕🍝 ünïcode " * 50
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [event])

        assert_equal [event], store.get_events(Sentiero::WindowRef.new("s1", "w1"))
      end

      def test_opening_a_store_compresses_existing_plain_text_rows
        # Simulate a pre-compression database: schema in place, but payloads
        # stored as plain TEXT and user_version at 0 (as every pre-feature
        # file is).
        legacy = big_event
        legacy_json = JSON.generate(legacy)
        seed = open_sqlite_store(path: @db_path)
        seed.save_events(Sentiero::WindowRef.new("s1", "w1"), [small_event])
        raw_db do |db|
          db.execute("UPDATE events SET data = ?", [legacy_json])
          db.execute("PRAGMA user_version = 0")
        end

        reopened = open_sqlite_store(path: @db_path)

        raw_db do |db|
          assert_equal "blob", db.get_first_value("SELECT typeof(data) FROM events"),
            "reopening the store should compress pre-existing large text payloads"
        end
        assert_equal [legacy], reopened.get_events(Sentiero::WindowRef.new("s1", "w1"))
      end
    end
  end
end
