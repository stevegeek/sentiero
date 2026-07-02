# frozen_string_literal: true

# Shared contract tests for any Sentiero::Store implementation.
#
# Including test class must define:
#   def create_store  =>  a fresh Sentiero::Store instance
#
module StoreContractTests
  def setup
    @store = create_store
  end

  # Builds a WindowRef for the (session_id, window_id) pair that addresses a
  # single window. Keeps the many window-level store calls below readable.
  def ref(session_id, window_id)
    Sentiero::WindowRef.new(session_id, window_id)
  end

  def make_event(timestamp:, type: "mouse", data: {})
    {"timestamp" => timestamp, "type" => type, "data" => data}
  end

  def make_events(count, start_ts: 1000.0, step: 1.0)
    count.times.map { |i| make_event(timestamp: start_ts + (i * step)) }
  end

  def test_save_events_stores_events
    events = make_events(3)
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"))
    assert_equal 3, result.size
    assert_equal events, result
  end

  def test_save_events_appends_on_subsequent_calls
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 2.0)])

    result = @store.get_events(ref("s1", "w1"))
    assert_equal 2, result.size
    assert_equal 1.0, result[0]["timestamp"]
    assert_equal 2.0, result[1]["timestamp"]
  end

  def test_get_events_returns_timestamp_order_for_out_of_order_inserts
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 3.0)])
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0), make_event(timestamp: 2.0)])

    result = @store.get_events(ref("s1", "w1"))
    assert_equal [1.0, 2.0, 3.0], result.map { |event| event["timestamp"] }
  end

  def test_get_events_after_cursor_respects_timestamp_order_for_out_of_order_inserts
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 3.0)])
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0), make_event(timestamp: 2.0)])

    result = @store.get_events(ref("s1", "w1"), after: 1.5)
    assert_equal [2.0, 3.0], result.map { |event| event["timestamp"] }
  end

  def test_max_events_per_session_caps_and_keeps_newest
    @store.limits = Sentiero::Store::Limits.new(max_events_per_session: 3)
    (1..5).each { |ts| @store.save_events(ref("s1", "w1"), [make_event(timestamp: ts.to_f)]) }

    result = @store.get_events(ref("s1", "w1"))
    assert_equal [3.0, 4.0, 5.0], result.map { |event| event["timestamp"] }
  end

  def test_max_sessions_evicts_oldest_keeping_newest
    @store.limits = Sentiero::Store::Limits.new(max_sessions: 2)
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.01
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])
    sleep 0.01
    @store.save_events(ref("s3", "w1"), [make_event(timestamp: 3.0)])

    ids = @store.list_sessions(limit: 10).map { |summary| summary[:session_id] }
    assert_equal 2, ids.size
    assert_includes ids, "s3"
    refute_includes ids, "s1"
  end

  def test_save_events_ignores_nil
    @store.save_events(ref("s1", "w1"), nil)
    assert_equal [], @store.get_events(ref("s1", "w1"))
  end

  def test_save_events_ignores_empty_array
    @store.save_events(ref("s1", "w1"), [])
    assert_equal [], @store.get_events(ref("s1", "w1"))
  end

  def test_multiple_windows_in_one_session
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    @store.save_events(ref("s1", "w2"), [make_event(timestamp: 2.0)])

    session = @store.get_session("s1")
    window_ids = session[:windows].map { |w| w[:window_id] }.sort
    assert_equal %w[w1 w2], window_ids

    assert_equal 1, @store.get_events(ref("s1", "w1")).size
    assert_equal 1, @store.get_events(ref("s1", "w2")).size
  end

  def test_list_sessions_returns_sessions_newest_first
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05 # ensure distinct updated_at
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])

    sessions = @store.list_sessions(limit: 10)
    assert_equal 2, sessions.size
    assert_equal "s2", sessions[0][:session_id]
    assert_equal "s1", sessions[1][:session_id]
  end

  def test_list_sessions_includes_window_ids_and_event_count
    @store.save_events(ref("s1", "w1"), make_events(3))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 2000.0))

    sessions = @store.list_sessions(limit: 10)
    assert_equal 1, sessions.size

    entry = sessions.first
    assert_equal "s1", entry[:session_id]
    assert_equal 5, entry[:event_count]
    assert_includes entry[:window_ids], "w1"
    assert_includes entry[:window_ids], "w2"
  end

  def test_list_sessions_pagination_with_limit
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])
    sleep 0.05
    @store.save_events(ref("s3", "w1"), [make_event(timestamp: 3.0)])

    page1 = @store.list_sessions(limit: 2)
    assert_equal 2, page1.size
    assert_equal "s3", page1[0][:session_id]
    assert_equal "s2", page1[1][:session_id]
  end

  def test_list_sessions_pagination_with_offset
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])
    sleep 0.05
    @store.save_events(ref("s3", "w1"), [make_event(timestamp: 3.0)])

    page2 = @store.list_sessions(limit: 2, offset: 2)
    assert_equal 1, page2.size
    assert_equal "s1", page2[0][:session_id]
  end

  def test_list_sessions_returns_empty_when_no_sessions
    sessions = @store.list_sessions(limit: 10)
    assert_equal [], sessions
  end

  def test_list_sessions_returns_empty_for_out_of_range_offset
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sessions = @store.list_sessions(limit: 10, offset: 100)
    assert_equal [], sessions
  end

  def test_get_session_returns_windows_metadata
    @store.save_events(ref("s1", "w1"), make_events(4))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 5000.0))

    session = @store.get_session("s1")

    assert_equal "s1", session[:session_id]
    assert_kind_of Float, session[:created_at]
    assert_kind_of Float, session[:updated_at]

    windows = session[:windows].sort_by { |w| w[:window_id] }
    assert_equal 2, windows.size
    assert_equal "w1", windows[0][:window_id]
    assert_equal 4, windows[0][:event_count]
    assert_equal "w2", windows[1][:window_id]
    assert_equal 2, windows[1][:event_count]
  end

  def test_get_session_includes_per_window_timestamps
    @store.save_events(ref("s1", "w1"), make_events(3, start_ts: 1000.0, step: 100.0))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 5000.0, step: 200.0))

    session = @store.get_session("s1")
    windows = session[:windows].sort_by { |w| w[:window_id] }

    # w1: timestamps 1000, 1100, 1200
    assert_in_delta 1000.0, windows[0][:first_event_at], 0.1
    assert_in_delta 1200.0, windows[0][:last_event_at], 0.1

    # w2: timestamps 5000, 5200
    assert_in_delta 5000.0, windows[1][:first_event_at], 0.1
    assert_in_delta 5200.0, windows[1][:last_event_at], 0.1
  end

  def test_get_session_returns_nil_for_nonexistent
    assert_nil @store.get_session("nonexistent")
  end

  def test_get_session_rejects_malformed_id
    assert_raises(ArgumentError) { @store.get_session("bad id!") }
  end

  def test_get_events_returns_all_events_for_window
    events = make_events(5)
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"))
    assert_equal 5, result.size
    assert_equal events, result
  end

  def test_get_events_with_after_cursor
    events = make_events(5, start_ts: 100.0, step: 10.0)
    # timestamps: 100, 110, 120, 130, 140
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"), after: 120.0)
    assert_equal 2, result.size
    assert_equal 130.0, result[0]["timestamp"]
    assert_equal 140.0, result[1]["timestamp"]
  end

  def test_get_events_with_after_cursor_returns_empty_when_none_match
    events = make_events(3, start_ts: 10.0, step: 1.0)
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"), after: 999.0)
    assert_equal [], result
  end

  def test_get_events_with_limit
    events = make_events(10)
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"), limit: 3)
    assert_equal 3, result.size
  end

  def test_get_events_with_after_and_limit
    events = make_events(10, start_ts: 100.0, step: 10.0)
    # timestamps: 100, 110, 120, 130, 140, 150, 160, 170, 180, 190
    @store.save_events(ref("s1", "w1"), events)

    result = @store.get_events(ref("s1", "w1"), after: 140.0, limit: 2)
    assert_equal 2, result.size
    assert_equal 150.0, result[0]["timestamp"]
    assert_equal 160.0, result[1]["timestamp"]
  end

  def test_get_events_returns_empty_for_nonexistent_session
    assert_equal [], @store.get_events(ref("nonexistent", "w1"))
  end

  def test_get_events_returns_empty_for_nonexistent_window
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    assert_equal [], @store.get_events(ref("s1", "nonexistent"))
  end

  def test_get_events_rejects_malformed_window_ref
    assert_raises(ArgumentError) { @store.get_events(ref("bad id!", "w1")) }
    assert_raises(ArgumentError) { @store.get_events(ref("s1", "bad id!")) }
  end

  def test_delete_session_cascade_deletes_everything
    @store.save_events(ref("s1", "w1"), make_events(3))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 2000.0))

    @store.delete_session("s1")

    assert_nil @store.get_session("s1")
    assert_equal [], @store.get_events(ref("s1", "w1"))
    assert_equal [], @store.get_events(ref("s1", "w2"))
    assert_equal [], @store.list_sessions(limit: 10)
  end

  def test_delete_session_does_not_affect_other_sessions
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])

    @store.delete_session("s1")

    assert_nil @store.get_session("s1")
    refute_nil @store.get_session("s2")
  end

  def test_delete_nonexistent_session_does_not_raise
    @store.delete_session("nonexistent") # should not raise
  end

  def test_delete_session_rejects_malformed_id
    assert_raises(ArgumentError) { @store.delete_session("bad id!") }
  end

  def test_delete_window_removes_window_events
    @store.save_events(ref("s1", "w1"), make_events(3))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 2000.0))

    @store.delete_window(ref("s1", "w1"))

    assert_equal [], @store.get_events(ref("s1", "w1"))
    assert_equal 2, @store.get_events(ref("s1", "w2")).size
  end

  def test_delete_window_removes_session_when_last_window_deleted
    @store.save_events(ref("s1", "w1"), make_events(3))

    @store.delete_window(ref("s1", "w1"))

    assert_nil @store.get_session("s1")
    assert_equal [], @store.list_sessions(limit: 10)
  end

  def test_delete_window_keeps_session_when_other_windows_remain
    @store.save_events(ref("s1", "w1"), make_events(2))
    @store.save_events(ref("s1", "w2"), make_events(3, start_ts: 2000.0))

    @store.delete_window(ref("s1", "w1"))

    session = @store.get_session("s1")
    refute_nil session
    assert_equal 1, session[:windows].size
    assert_equal "w2", session[:windows][0][:window_id]
  end

  def test_delete_nonexistent_window_does_not_raise
    @store.delete_window(ref("nonexistent", "w1")) # should not raise
  end

  def test_delete_window_rejects_malformed_window_ref
    assert_raises(ArgumentError) { @store.delete_window(ref("bad id!", "w1")) }
    assert_raises(ArgumentError) { @store.delete_window(ref("s1", "bad id!")) }
  end

  def test_delete_window_of_last_window_keeps_error_data
    @store.save_events(ref("s1", "w1"), make_events(1))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_dw", session_id: "s1", timestamp: 1.0))
    @store.save_server_event(make_server_event(name: "ev_dw", session_id: "s1", timestamp: 1.0))

    @store.delete_window(ref("s1", "w1")) # the only window, so the session itself goes away
    assert_nil @store.get_session("s1")

    assert_equal 1, @store.occurrences_for_session("s1").size
    assert_equal 1, @store.server_events_for_session("s1").size
    refute_nil @store.get_problem("fp_dw")
  end

  def test_list_sessions_includes_event_timestamp_range
    @store.save_events(ref("s1", "w1"), [
      make_event(timestamp: 1000.0),
      make_event(timestamp: 2000.0),
      make_event(timestamp: 3000.0)
    ])

    sessions = @store.list_sessions(limit: 10)
    entry = sessions.first
    assert_equal 1000.0, entry[:first_event_at]
    assert_equal 3000.0, entry[:last_event_at]
  end

  def test_get_session_includes_event_timestamp_range
    @store.save_events(ref("s1", "w1"), [
      make_event(timestamp: 1000.0),
      make_event(timestamp: 5000.0)
    ])

    session = @store.get_session("s1")
    assert_equal 1000.0, session[:first_event_at]
    assert_equal 5000.0, session[:last_event_at]
  end

  def test_save_metadata_stores_session_metadata
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_metadata("s1", {"url" => "https://example.com", "userAgent" => "Mozilla/5.0"})

    session = @store.get_session("s1")
    assert session[:metadata], "Expected session to have metadata"
    assert_equal "https://example.com", session[:metadata]["url"]
    assert_equal "Mozilla/5.0", session[:metadata]["userAgent"]
  end

  def test_save_metadata_merges_across_calls
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_metadata("s1", {"url" => "https://example.com"})
    @store.save_metadata("s1", {"userId" => "user-123"})

    session = @store.get_session("s1")
    assert_equal "https://example.com", session[:metadata]["url"]
    assert_equal "user-123", session[:metadata]["userId"]
  end

  def test_save_metadata_ignores_nonexistent_session
    # Should not raise
    @store.save_metadata("nonexistent", {"url" => "https://example.com"})
  end

  def test_save_metadata_has_errors_flag_persists
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_metadata("s1", {"has_errors" => true})

    session = @store.get_session("s1")
    assert session[:metadata], "Expected session to have metadata"
    assert session[:metadata]["has_errors"], "Expected has_errors flag to be truthy"

    sessions = @store.list_sessions(limit: 10)
    entry = sessions.find { |s| s[:session_id] == "s1" }
    assert entry[:metadata], "Expected list entry to have metadata"
    assert entry[:metadata]["has_errors"], "Expected has_errors flag in list_sessions"
  end

  def test_save_metadata_appears_in_list_sessions
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_metadata("s1", {"url" => "https://example.com"})

    sessions = @store.list_sessions(limit: 10)
    entry = sessions.first
    assert entry[:metadata], "Expected list entry to have metadata"
    assert_equal "https://example.com", entry[:metadata]["url"]
  end

  def test_list_sessions_with_search_by_session_id
    @store.save_events(ref("abc-123", "w1"), [make_event(timestamp: 1000.0)])
    sleep 0.05
    @store.save_events(ref("xyz-789", "w1"), [make_event(timestamp: 2000.0)])

    sessions = @store.list_sessions(limit: 10, search: "abc")
    assert_equal 1, sessions.size
    assert_equal "abc-123", sessions[0][:session_id]
  end

  def test_list_sessions_with_search_by_metadata
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_metadata("s1", {"url" => "https://example.com/dashboard"})
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2000.0)])
    @store.save_metadata("s2", {"url" => "https://other.com/login"})

    sessions = @store.list_sessions(limit: 10, search: "dashboard")
    assert_equal 1, sessions.size
    assert_equal "s1", sessions[0][:session_id]
  end

  def test_list_sessions_sort_by_created_at
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2000.0)])

    sessions = @store.list_sessions(limit: 10, sort_by: "created_at")
    assert_equal 2, sessions.size
    assert_equal "s2", sessions[0][:session_id]
    assert_equal "s1", sessions[1][:session_id]
  end

  def test_list_sessions_sort_by_event_count
    @store.save_events(ref("s1", "w1"), make_events(5))
    sleep 0.05
    @store.save_events(ref("s2", "w1"), make_events(2, start_ts: 2000.0))
    sleep 0.05
    @store.save_events(ref("s3", "w1"), make_events(10, start_ts: 3000.0))

    sessions = @store.list_sessions(limit: 10, sort_by: "event_count")
    assert_equal 3, sessions.size
    assert_equal "s3", sessions[0][:session_id]
    assert_equal "s1", sessions[1][:session_id]
    assert_equal "s2", sessions[2][:session_id]
  end

  def test_list_sessions_since_filters_old_sessions
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2000.0)])

    sessions = @store.list_sessions(limit: 10, since: cutoff)
    assert_equal 1, sessions.size
    assert_equal "s2", sessions[0][:session_id]
  end

  def test_list_sessions_until_time_filters_new_sessions
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2000.0)])

    sessions = @store.list_sessions(limit: 10, until_time: cutoff)
    assert_equal 1, sessions.size
    assert_equal "s1", sessions[0][:session_id]
  end

  def test_list_sessions_since_and_until_time_combined
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    sleep 0.05
    start_time = Time.now
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2000.0)])
    sleep 0.05
    end_time = Time.now
    sleep 0.05
    @store.save_events(ref("s3", "w1"), [make_event(timestamp: 3000.0)])

    sessions = @store.list_sessions(limit: 10, since: start_time, until_time: end_time)
    assert_equal 1, sessions.size
    assert_equal "s2", sessions[0][:session_id]
  end

  def test_each_session_events_yields_each_window_with_events
    @store.save_events(ref("s1", "w1"), make_events(2, start_ts: 1000.0))
    @store.save_events(ref("s1", "w2"), make_events(3, start_ts: 2000.0))

    yielded = []
    @store.each_session_events do |session, window_id, events|
      yielded << [session[:session_id], window_id, events.size]
    end

    assert_equal 2, yielded.size
    assert(yielded.all? { |sid, _, _| sid == "s1" })
    by_window = yielded.to_h { |_, wid, count| [wid, count] }
    assert_equal 2, by_window["w1"]
    assert_equal 3, by_window["w2"]
  end

  def test_each_session_events_passes_actual_events
    events = make_events(3, start_ts: 100.0, step: 10.0)
    @store.save_events(ref("s1", "w1"), events)

    captured = nil
    @store.each_session_events { |_session, _wid, evts| captured = evts }

    assert_equal events, captured
  end

  def test_each_session_events_newest_sessions_first
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])

    order = []
    @store.each_session_events { |session, _wid, _evts| order << session[:session_id] }

    assert_equal %w[s2 s1], order
  end

  def test_each_session_events_respects_limit
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])
    sleep 0.05
    @store.save_events(ref("s3", "w1"), [make_event(timestamp: 3.0)])

    seen = []
    @store.each_session_events(limit: 2) { |session, _wid, _evts| seen << session[:session_id] }

    assert_equal %w[s3 s2], seen
  end

  def test_each_session_events_returns_enumerator_without_block
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])

    enum = @store.each_session_events
    assert_kind_of Enumerator, enum
    results = enum.to_a
    assert_equal 1, results.size
    assert_equal "s1", results.first[0][:session_id]
  end

  def test_each_session_events_empty_store_yields_nothing
    count = 0
    @store.each_session_events { |_s, _w, _e| count += 1 }
    assert_equal 0, count
  end

  def test_each_session_events_filters_by_since_and_until
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])

    seen = []
    @store.each_session_events(since: cutoff) { |session, _w, _e| seen << session[:session_id] }
    assert_equal %w[s2], seen
  end

  def test_event_timestamp_range_updates_across_batches
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 2000.0)])
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1000.0)])
    @store.save_events(ref("s1", "w2"), [make_event(timestamp: 5000.0)])

    session = @store.get_session("s1")
    assert_equal 1000.0, session[:first_event_at]
    assert_equal 5000.0, session[:last_event_at]

    sessions = @store.list_sessions(limit: 10)
    entry = sessions.first
    assert_equal 1000.0, entry[:first_event_at]
    assert_equal 5000.0, entry[:last_event_at]
  end

  def test_purge_older_than_deletes_sessions_older_than_window
    @store.save_events(ref("old", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.1
    cutoff_age = Time.now.to_f - @store.list_sessions(limit: 10).find { |s| s[:session_id] == "old" }[:updated_at]
    @store.save_events(ref("recent", "w1"), [make_event(timestamp: 2.0)])

    deleted = @store.purge_older_than(cutoff_age - 0.01)

    assert_equal 1, deleted
    assert_nil @store.get_session("old")
    refute_nil @store.get_session("recent")
  end

  def test_purge_older_than_returns_zero_on_empty_store
    assert_equal 0, @store.purge_older_than(60)
  end

  def test_purge_older_than_keeps_all_recent_sessions
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    @store.save_events(ref("s2", "w1"), [make_event(timestamp: 2.0)])

    deleted = @store.purge_older_than(3600)

    assert_equal 0, deleted
    assert_equal 2, @store.list_sessions(limit: 10).size
  end

  def test_purge_older_than_cascades_to_events
    @store.save_events(ref("s1", "w1"), make_events(3))
    @store.save_events(ref("s1", "w2"), make_events(2, start_ts: 2000.0))
    sleep 0.1

    @store.purge_older_than(0.01)

    assert_equal [], @store.get_events(ref("s1", "w1"))
    assert_equal [], @store.get_events(ref("s1", "w2"))
  end

  def test_purge_older_than_is_idempotent
    @store.save_events(ref("s1", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.1

    assert_equal 1, @store.purge_older_than(0.01)
    assert_equal 0, @store.purge_older_than(0.01)
  end

  def test_purge_older_than_purges_beyond_scan_cap
    @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 3)
    session_count = 4 # one more than the cap

    session_count.times { |i| @store.save_events(ref("s#{i}", "w1"), [make_event(timestamp: i.to_f)]) }
    sleep 0.1

    deleted = @store.purge_older_than(0.01)

    assert_equal session_count, deleted
    assert_equal [], @store.list_sessions(limit: 100)
  end

  def test_erase_sessions_removes_exactly_the_given_ids
    @store.save_events(ref("keep", "w1"), [make_event(timestamp: 1.0)])
    @store.save_events(ref("drop", "w1"), [make_event(timestamp: 2.0)])

    deleted = Sentiero::Erasure.erase_sessions(@store, ["drop", "absent"])

    assert_equal 1, deleted
    assert_nil @store.get_session("drop")
    refute_nil @store.get_session("keep")
  end

  def test_erase_where_removes_only_in_range_sessions
    @store.save_events(ref("old", "w1"), [make_event(timestamp: 1.0)])
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    @store.save_events(ref("new", "w1"), [make_event(timestamp: 2.0)])

    deleted = Sentiero::Erasure.erase_where(@store, since: cutoff)

    assert_equal 1, deleted
    assert_nil @store.get_session("new")
    refute_nil @store.get_session("old")
  end
end
