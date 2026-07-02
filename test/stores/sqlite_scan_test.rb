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

      private

      def count_statements
        db = @store.instance_variable_get(:@db)
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
