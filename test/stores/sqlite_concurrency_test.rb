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
    # The store shares one SQLite3 connection across all callers. sqlite3 releases
    # the GVL during DB calls, so concurrent writers (the expected EventsApp path
    # under Puma) can interleave statements and race on the connection's single
    # transaction state ("cannot start a transaction within a transaction"). These
    # tests pin that all access is serialized.
    class SQLiteConcurrencyTest < Minitest::Test
      # Holds save_events' transaction open (enforce_max_events runs inside it) so
      # a second writer deterministically collides on the shared connection unless
      # access is serialized. Without the in-transaction delay the race is real but
      # timing-dependent — too narrow under MRI's GVL to trigger reliably in a unit
      # test, though it surfaces under real production I/O.
      class SlowSQLite < Sentiero::Stores::SQLite
        def enforce_max_events(*)
          sleep 0.02
          super
        end
      end

      def setup
        skip "sqlite3 gem not available" unless SQLITE_AVAILABLE
        @tmpdir = Dir.mktmpdir("sentiero_sqlite_concurrency")
        @db_path = ::File.join(@tmpdir, "test.db")
      end

      def teardown
        FileUtils.rm_rf(@tmpdir) if @tmpdir && ::File.directory?(@tmpdir)
      end

      def test_overlapping_writes_do_not_race_on_the_shared_connection
        store = SlowSQLite.new(path: @db_path)
        errors = collect_errors do |t|
          store.save_events(Sentiero::WindowRef.new("session-#{t}", "w1"),
            [{"timestamp" => 1.0, "type" => 3}])
        end

        assert_empty errors, "concurrent save_events raced on the shared connection"
      end

      def test_concurrent_load_keeps_every_event
        store = Sentiero::Stores::SQLite.new(path: @db_path)
        writes = 25
        errors = collect_errors(threads: 12) do |t|
          writes.times do |i|
            store.save_events(Sentiero::WindowRef.new("session-#{t}", "w1"),
              [{"timestamp" => (i + 1).to_f, "type" => 3}])
          end
        end

        assert_empty errors
        12.times do |t|
          events = store.get_events(Sentiero::WindowRef.new("session-#{t}", "w1"))
          assert_equal writes, events.length, "lost events for session-#{t}"
        end
      end

      # Dashboard analytics scans hold the store for seconds on big databases.
      # Recorder beacons (EventsApp POSTs) must not queue behind them: a
      # save_events issued while a scan's consumer is mid-yield has to complete
      # promptly, not after the whole scan finishes.
      def test_save_events_is_not_blocked_by_a_slow_scan
        store = Sentiero::Stores::SQLite.new(path: @db_path)
        3.times do |i|
          store.save_events(Sentiero::WindowRef.new("session-#{i}", "w1"),
            [{"timestamp" => (i + 1).to_f, "type" => 3}])
        end

        scan_started = Queue.new
        scanner = Thread.new do
          store.each_session_events do |_summary, _wid, _events|
            scan_started << true
            sleep 0.3
          end
        end

        scan_started.pop
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        store.save_events(Sentiero::WindowRef.new("write-during-scan", "w1"),
          [{"timestamp" => 99.0, "type" => 3}])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_operator elapsed, :<, 0.25,
          "save_events waited #{elapsed.round(3)}s behind an in-progress scan"
      ensure
        scanner&.join
      end

      private

      def collect_errors(threads: 3)
        errors = Concurrent::Array.new
        Array.new(threads) { |t|
          Thread.new do
            yield t
          rescue => e
            errors << "#{e.class}: #{e.message}"
          end
        }.each(&:join)
        errors.uniq
      end
    end
  end
end
