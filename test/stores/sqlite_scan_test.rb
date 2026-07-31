# frozen_string_literal: true

require "test_helper"
require "tmpdir"

begin
  require "sqlite3"
  SQLITE_AVAILABLE = true unless defined?(SQLITE_AVAILABLE)
rescue LoadError
  SQLITE_AVAILABLE = false unless defined?(SQLITE_AVAILABLE)
end

require "sentiero/stores/sqlite" if SQLITE_AVAILABLE

module Sentiero
  module Stores
    # Correctness of each_session_events lives in the shared store contract; this
    # pins that the override stays batched (constant queries) rather than N+1.
    class SQLiteScanTest < Minitest::Test
      def setup
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE
        @tmpdir = Dir.mktmpdir("sentiero_sqlite_scan")
        @store = Sentiero::Stores::SQLite.new(path: ::File.join(@tmpdir, "test.db"))
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def test_scan_query_count_does_not_grow_with_session_count
        20.times do |i|
          @store.save_events(Sentiero::WindowRef.new("s#{i}", "w1"), [{"timestamp" => i.to_f, "type" => 3}])
          @store.save_events(Sentiero::WindowRef.new("s#{i}", "w2"), [{"timestamp" => i + 0.5, "type" => 3}])
        end

        statements = count_statements { @store.each_session_events { |_s, _w, _e| } }

        # 1 session query + 1 events query (single id chunk). The base N+1 would
        # issue dozens for 20 sessions x 2 windows.
        assert_operator statements, :<=, 3, "each_session_events should be batched, saw #{statements} queries"
      end

      # The perf point of the types: filter — DOM snapshots (type 2) dominate
      # the stored bytes, and a typed scan must skip them in SQL, never
      # fetching or parsing their payloads. Corrupting the snapshot's stored
      # JSON makes any read of it fail loudly, so success proves the pushdown.
      def test_typed_scan_never_reads_filtered_payloads
        @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [
          {"timestamp" => 1.0, "type" => 2, "data" => {"node" => {}}},
          {"timestamp" => 2.0, "type" => 5, "data" => {"tag" => "navigation"}}
        ])
        @store.send(:db).execute("UPDATE events SET data = '{corrupt' WHERE type = 2")

        captured = nil
        @store.each_session_events(types: [4, 5]) { |_s, _w, evts| captured = evts }
        assert_equal [5], captured.map { |event| event["type"] }

        assert_raises(JSON::ParserError) do
          @store.each_session_events { |_s, _w, _e| }
        end
      end

      private

      def count_statements
        # The store's connection is per-thread; the scan below runs on this
        # thread, so tracing this thread's connection sees all its statements.
        db = @store.send(:db)
        count = 0
        db.trace { |_sql| count += 1 }
        yield
        count
      ensure
        db.trace(nil)
      end
    end
  end
end
