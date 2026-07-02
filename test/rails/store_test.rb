# frozen_string_literal: true

require_relative "test_helper"
require_relative "../store_contract_tests"
require_relative "../error_store_contract_tests"

class Sentiero::Rails::StoreTest < Minitest::Test
  include StoreContractTests
  include ErrorStoreContractTests

  def create_store
    Sentiero::Rails::Session.delete_all
    Sentiero::Rails::Event.delete_all
    Sentiero::Rails::Problem.delete_all
    Sentiero::Rails::Occurrence.delete_all
    Sentiero::Rails::ServerEvent.delete_all
    Sentiero.reset_configuration!
    Sentiero::Rails::Store.new
  end

  # --- Security tests ---

  def test_max_events_per_session_enforced
    @store.limits = Sentiero::Store::Limits.new(max_events_per_session: 5)

    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), make_events(3, start_ts: 100.0))
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), make_events(5, start_ts: 200.0))

    events = @store.get_events(Sentiero::WindowRef.new("s1", "w1"))
    assert_equal 5, events.size
    # Oldest events (100.0, 101.0, 102.0) should have been dropped
    assert_operator events.first["timestamp"], :>=, 200.0
  ensure
    Sentiero.reset_configuration!
  end

  def test_max_sessions_enforced
    @store.limits = Sentiero::Store::Limits.new(max_sessions: 2)

    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    @store.save_events(Sentiero::WindowRef.new("s2", "w1"), [make_event(timestamp: 2.0)])
    sleep 0.05
    @store.save_events(Sentiero::WindowRef.new("s3", "w1"), [make_event(timestamp: 3.0)])

    sessions = @store.list_sessions(limit: 10)
    assert_equal 2, sessions.size

    session_ids = sessions.map { |s| s[:session_id] }
    # s1 (oldest) should have been evicted
    refute_includes session_ids, "s1"
    assert_includes session_ids, "s2"
    assert_includes session_ids, "s3"
  ensure
    Sentiero.reset_configuration!
  end

  def test_concurrent_save_events_no_duplicate_sessions
    # Test sequential race condition handling (find_or_create_by + RecordNotUnique rescue).
    # True concurrency requires a multi-connection DB (PostgreSQL/MySQL).
    # With SQLite in-memory we test the retry logic sequentially.
    5.times do |i|
      @store.save_events(Sentiero::WindowRef.new("concurrent_s", "w#{i}"), [make_event(timestamp: i.to_f)])
    end

    session_count = Sentiero::Rails::Session.where(session_id: "concurrent_s").count
    assert_equal 1, session_count

    session = @store.get_session("concurrent_s")
    refute_nil session
    assert_equal 5, session[:windows].size
  end

  def test_sql_injection_in_session_id
    malicious_id = "'; DROP TABLE sentiero_sessions; --"
    # This should not raise or corrupt the database
    @store.save_events(Sentiero::WindowRef.new(malicious_id, "w1"), [make_event(timestamp: 1.0)])

    # Table should still exist and work
    sessions = @store.list_sessions(limit: 10)
    assert_kind_of Array, sessions
  end

  def test_event_data_stored_and_retrieved_as_is
    html_data = {"type" => "mutation", "data" => {"html" => "<script>alert('xss')</script>"}}
    events = [{"timestamp" => 1.0, "type" => "mutation", "data" => html_data}]
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), events)

    result = @store.get_events(Sentiero::WindowRef.new("s1", "w1"))
    assert_equal 1, result.size
    assert_equal html_data, result[0]["data"]
  end

  def test_purge_older_than_deletes_rows_via_delete_all
    @store.save_events(Sentiero::WindowRef.new("old", "w1"), [make_event(timestamp: 1.0)])
    Sentiero::Rails::Session.where(session_id: "old").update_all(updated_at: 2.hours.ago)
    @store.save_events(Sentiero::WindowRef.new("recent", "w1"), [make_event(timestamp: 2.0)])

    deleted = @store.purge_older_than(3600)

    assert_equal 1, deleted
    assert_equal 0, Sentiero::Rails::Session.where(session_id: "old").count
    assert_equal 0, Sentiero::Rails::Event.where(session_id: "old").count
    assert_equal 1, Sentiero::Rails::Session.where(session_id: "recent").count
  end

  def test_save_metadata_reads_fresh_value_under_lock
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [make_event(timestamp: 1.0)])
    @store.save_metadata("s1", {"a" => "1"})

    # Simulate a concurrent writer (e.g. save_occurrence's has_errors merge)
    # committing "b" directly to the row, underneath a `session` object a
    # racing thread had already loaded before that commit.
    stale_session = Sentiero::Rails::Session.find_by(session_id: "s1")
    Sentiero::Rails::Session.where(session_id: "s1").update_all(metadata: {"a" => "1", "b" => "2"})

    Sentiero::Rails::Session.stub(:find_by, stale_session) do
      @store.save_metadata("s1", {"c" => "3"})
    end

    metadata = Sentiero::Rails::Session.find_by(session_id: "s1").metadata
    assert_equal({"a" => "1", "b" => "2", "c" => "3"}, metadata,
      "save_metadata must reload under lock instead of merging against a stale in-memory copy")
  end

  def test_save_occurrence_recovers_from_problem_insert_race
    occurrence = {
      "fingerprint" => "race_fp", "project" => "proj",
      "exception_class" => "RuntimeError", "message" => "boom", "timestamp" => 1.0
    }
    # Simulate a concurrent insert: a competing process creates the Problem
    # row after our find_or_initialize_by returns a fresh (unpersisted) record,
    # so our save! hits the unique index on fingerprint.
    Sentiero::Rails::Problem.create!(
      fingerprint: "race_fp", project: "proj", exception_class: "RuntimeError",
      title: "RuntimeError", message: "earlier", count: 1, status: "open",
      first_seen: 0.5, last_seen: 0.5
    )

    calls = 0
    original = Sentiero::Rails::Problem.method(:find_or_initialize_by)
    fake = lambda do |*args, **kwargs, &blk|
      calls += 1
      if calls == 1
        Sentiero::Rails::Problem.new(fingerprint: "race_fp")
      else
        original.call(*args, **kwargs, &blk)
      end
    end

    Sentiero::Rails::Problem.stub(:find_or_initialize_by, fake) do
      assert_equal "race_fp", @store.save_occurrence(occurrence)
    end

    problem = Sentiero::Rails::Problem.find_by(fingerprint: "race_fp")
    assert_equal 2, problem.count            # touched, not duplicated
    assert_equal 1, Sentiero::Rails::Problem.where(fingerprint: "race_fp").count
    assert_equal 1, Sentiero::Rails::Occurrence.where(fingerprint: "race_fp").count
  end
end
