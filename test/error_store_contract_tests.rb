# frozen_string_literal: true

# Shared contract for stores that implement the error-tracking API
# (save_occurrence / list_problems / get_problem / get_occurrences /
# count_occurrences / update_problem_status / save_server_event /
# list_server_events).
#
# Include in a backend test that also defines `create_store` (the existing
# StoreContractTests setup already assigns @store = create_store).
module ErrorStoreContractTests
  def make_occurrence(fingerprint: "fp_1", project: "app", exception_class: "RuntimeError",
    message: "boom", timestamp: 1000.0, backtrace: nil, context: nil,
    session_id: nil, window_id: nil)
    occ = {
      "fingerprint" => fingerprint,
      "project" => project,
      "exception_class" => exception_class,
      "message" => message,
      "timestamp" => timestamp
    }
    occ["backtrace"] = backtrace if backtrace
    occ["context"] = context if context
    occ["session_id"] = session_id if session_id
    occ["window_id"] = window_id if window_id
    occ
  end

  def make_server_event(project: "app", name: "signup", level: "info",
    payload: nil, session_id: nil, timestamp: 1000.0)
    ev = {"project" => project, "name" => name, "level" => level, "timestamp" => timestamp}
    ev["payload"] = payload if payload
    ev["session_id"] = session_id if session_id
    ev
  end

  # --- save_occurrence + problem upsert ---------------------------------

  def test_save_occurrence_creates_open_problem
    fp = @store.save_occurrence(make_occurrence(fingerprint: "fp_a", timestamp: 1000.0))
    assert_equal "fp_a", fp

    problem = @store.get_problem("fp_a")
    refute_nil problem
    assert_equal "fp_a", problem[:id]
    assert_equal "app", problem[:project]
    assert_equal "RuntimeError", problem[:exception_class]
    assert_equal 1, problem[:count]
    assert_equal "open", problem[:status]
    assert_equal 1000.0, problem[:first_seen]
    assert_equal 1000.0, problem[:last_seen]
    assert_nil problem[:resolved_at]
  end

  def test_repeat_occurrence_increments_count_and_extends_last_seen
    @store.save_occurrence(make_occurrence(fingerprint: "fp_b", message: "first", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_b", message: "second", timestamp: 2000.0))

    problem = @store.get_problem("fp_b")
    assert_equal 2, problem[:count]
    assert_equal 1000.0, problem[:first_seen]
    assert_equal 2000.0, problem[:last_seen]
    assert_equal "second", problem[:message]
  end

  def test_distinct_fingerprints_are_separate_problems
    @store.save_occurrence(make_occurrence(fingerprint: "fp_c1"))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_c2"))
    ids = @store.list_problems(project: "app", limit: 10).map { |p| p[:id] }
    assert_includes ids, "fp_c1"
    assert_includes ids, "fp_c2"
  end

  def test_get_problem_returns_nil_for_unknown
    assert_nil @store.get_problem("nope")
  end

  # --- list_problems filters/sort -------------------------------------

  def test_list_problems_scopes_by_project
    @store.save_occurrence(make_occurrence(fingerprint: "fp_p1", project: "app"))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_p2", project: "other"))

    app_ids = @store.list_problems(project: "app", limit: 10).map { |p| p[:id] }
    assert_includes app_ids, "fp_p1"
    refute_includes app_ids, "fp_p2"
  end

  def test_list_problems_filters_by_status
    @store.save_occurrence(make_occurrence(fingerprint: "fp_open"))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_res"))
    @store.update_problem_status("fp_res", "resolved")

    open_ids = @store.list_problems(project: "app", status: "open", limit: 10).map { |p| p[:id] }
    assert_includes open_ids, "fp_open"
    refute_includes open_ids, "fp_res"
  end

  def test_list_problems_default_sort_is_last_seen_desc
    @store.save_occurrence(make_occurrence(fingerprint: "fp_old", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_new", timestamp: 5000.0))
    ids = @store.list_problems(project: "app", limit: 10).map { |p| p[:id] }
    assert_equal "fp_new", ids.first
  end

  def test_list_problems_sort_by_first_seen_desc
    @store.save_occurrence(make_occurrence(fingerprint: "fp_fs1", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_fs2", timestamp: 2000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_fs1", timestamp: 3000.0)) # last_seen 3000, first_seen 1000

    ids = @store.list_problems(project: "app", sort_by: "first_seen", limit: 10).map { |p| p[:id] }
    assert_equal %w[fp_fs2 fp_fs1], ids, "first_seen sort must use first_seen (default last_seen sort would flip this)"
  end

  def test_list_problems_sort_by_count_desc
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ct1", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ct1", timestamp: 1500.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ct2", timestamp: 2000.0))

    ids = @store.list_problems(project: "app", sort_by: "count", limit: 10).map { |p| p[:id] }
    assert_equal %w[fp_ct1 fp_ct2], ids, "count sort must use count (default last_seen sort would flip this)"
  end

  def test_list_problems_search_matches_title_and_exception_class
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sr1", exception_class: "PaymentError", message: "card declined"))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sr2", exception_class: "RuntimeError", message: "boom"))

    # Matches the title ("RuntimeError: boom"), case-insensitively.
    by_title = @store.list_problems(project: "app", search: "BOOM", limit: 10).map { |p| p[:id] }
    assert_equal ["fp_sr2"], by_title

    # Matches the exception class.
    by_class = @store.list_problems(project: "app", search: "payment", limit: 10).map { |p| p[:id] }
    assert_equal ["fp_sr1"], by_class

    assert_empty @store.list_problems(project: "app", search: "nomatch", limit: 10)
  end

  def test_list_problems_offset_paginates
    @store.save_occurrence(make_occurrence(fingerprint: "fp_pg1", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_pg2", timestamp: 2000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_pg3", timestamp: 3000.0))

    page1 = @store.list_problems(project: "app", limit: 2).map { |p| p[:id] }
    page2 = @store.list_problems(project: "app", limit: 2, offset: 2).map { |p| p[:id] }
    assert_equal %w[fp_pg3 fp_pg2], page1
    assert_equal %w[fp_pg1], page2
    assert_empty @store.list_problems(project: "app", limit: 2, offset: 5)
  end

  # --- list_problems since/until_time bounds (on last_seen) ---------------

  def test_list_problems_filters_by_since_and_until_time
    @store.save_occurrence(make_occurrence(fingerprint: "fp_t1", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_t2", timestamp: 2000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_t3", timestamp: 3000.0))

    since_ids = @store.list_problems(project: nil, limit: 10, since: 1500.0).map { |p| p[:id] }
    refute_includes since_ids, "fp_t1"
    assert_includes since_ids, "fp_t2"
    assert_includes since_ids, "fp_t3"

    until_ids = @store.list_problems(project: nil, limit: 10, until_time: 2500.0).map { |p| p[:id] }
    assert_includes until_ids, "fp_t1"
    assert_includes until_ids, "fp_t2"
    refute_includes until_ids, "fp_t3"

    both_ids = @store.list_problems(project: nil, limit: 10, since: 1500.0, until_time: 2500.0).map { |p| p[:id] }
    assert_equal ["fp_t2"], both_ids
  end

  def test_list_problems_time_bounds_are_inclusive
    @store.save_occurrence(make_occurrence(fingerprint: "fp_edge", timestamp: 2000.0))

    ids = @store.list_problems(project: nil, limit: 10, since: 2000.0, until_time: 2000.0).map { |p| p[:id] }

    assert_includes ids, "fp_edge"
  end

  def test_list_problems_time_bounds_filter_on_last_seen_not_first_seen
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ls", timestamp: 1000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ls", timestamp: 5000.0)) # last_seen -> 5000

    since_ids = @store.list_problems(project: nil, limit: 10, since: 4000.0).map { |p| p[:id] }
    assert_includes since_ids, "fp_ls", "since must apply to last_seen (5000), not first_seen (1000)"

    until_ids = @store.list_problems(project: nil, limit: 10, until_time: 4000.0).map { |p| p[:id] }
    refute_includes until_ids, "fp_ls", "until_time must apply to last_seen (5000), not first_seen (1000)"
  end

  def test_list_problems_time_bounds_compose_with_status_filter
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ts1", timestamp: 2000.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ts2", timestamp: 2000.0))
    @store.update_problem_status("fp_ts2", "resolved")

    ids = @store.list_problems(project: nil, limit: 10, status: "open", since: 1000.0, until_time: 3000.0).map { |p| p[:id] }

    assert_includes ids, "fp_ts1"
    refute_includes ids, "fp_ts2"
  end

  # --- occurrences -----------------------------------------------------

  def test_get_occurrences_returns_stored_records_with_ids
    @store.save_occurrence(make_occurrence(fingerprint: "fp_occ", message: "one", timestamp: 1.0,
      session_id: "sess-1", backtrace: ["a", "b"]))
    occs = @store.get_occurrences("fp_occ")
    assert_equal 1, occs.size
    occ = occs.first
    assert_equal "one", occ["message"]
    assert_equal "sess-1", occ["session_id"]
    assert_equal ["a", "b"], occ["backtrace"]
    refute_nil occ["id"]
  end

  def test_get_occurrences_ascending_by_timestamp_with_after_cursor
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cur", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cur", timestamp: 2.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cur", timestamp: 3.0))

    all = @store.get_occurrences("fp_cur")
    assert_equal [1.0, 2.0, 3.0], all.map { |o| o["timestamp"] }

    after = @store.get_occurrences("fp_cur", after: 1.0)
    assert_equal [2.0, 3.0], after.map { |o| o["timestamp"] }

    limited = @store.get_occurrences("fp_cur", limit: 2)
    assert_equal [1.0, 2.0], limited.map { |o| o["timestamp"] }
  end

  def test_get_occurrences_empty_for_unknown_problem
    assert_equal [], @store.get_occurrences("nope")
  end

  # --- count_occurrences ------------------------------------------------

  def test_count_occurrences_with_and_without_after
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cnt", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cnt", timestamp: 2.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cnt", timestamp: 3.0))

    assert_equal 3, @store.count_occurrences("fp_cnt")
    assert_equal 1, @store.count_occurrences("fp_cnt", after: 2.0), "after is an exclusive cursor, like get_occurrences"
    assert_equal 0, @store.count_occurrences("fp_cnt", after: 3.0)
  end

  def test_count_occurrences_zero_for_unknown_problem
    assert_equal 0, @store.count_occurrences("nope")
  end

  def test_count_occurrences_agrees_with_get_occurrences
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cmp", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_cmp", timestamp: 2.0))

    assert_equal @store.get_occurrences("fp_cmp").size, @store.count_occurrences("fp_cmp")
    assert_equal @store.get_occurrences("fp_cmp", after: 1.0).size,
      @store.count_occurrences("fp_cmp", after: 1.0)
  end

  # --- status transitions + reopen ------------------------------------

  def test_update_problem_status_resolved_sets_resolved_at
    @store.save_occurrence(make_occurrence(fingerprint: "fp_r"))
    @store.update_problem_status("fp_r", "resolved")
    problem = @store.get_problem("fp_r")
    assert_equal "resolved", problem[:status]
    refute_nil problem[:resolved_at]
  end

  def test_update_problem_status_ignored_clears_resolved_at
    @store.save_occurrence(make_occurrence(fingerprint: "fp_i"))
    @store.update_problem_status("fp_i", "resolved")
    @store.update_problem_status("fp_i", "ignored")
    problem = @store.get_problem("fp_i")
    assert_equal "ignored", problem[:status]
    assert_nil problem[:resolved_at]
  end

  def test_resolved_problem_reopens_on_new_occurrence
    @store.save_occurrence(make_occurrence(fingerprint: "fp_re", timestamp: 1.0))
    @store.update_problem_status("fp_re", "resolved")
    @store.save_occurrence(make_occurrence(fingerprint: "fp_re", timestamp: 2.0))

    problem = @store.get_problem("fp_re")
    assert_equal "open", problem[:status]
    assert_nil problem[:resolved_at]
    assert_equal 2, problem[:count]
  end

  def test_update_problem_status_rejects_invalid_status
    @store.save_occurrence(make_occurrence(fingerprint: "fp_bad"))
    assert_raises(ArgumentError) { @store.update_problem_status("fp_bad", "banana") }
  end

  # --- server events ---------------------------------------------------

  def test_save_and_list_server_events
    @store.save_server_event(make_server_event(name: "signup", level: "info", timestamp: 1.0))
    events = @store.list_server_events(project: "app", limit: 10)
    assert_equal 1, events.size
    assert_equal "signup", events.first["name"]
    refute_nil events.first["id"]
  end

  def test_list_server_events_filters
    @store.save_server_event(make_server_event(name: "signup", level: "info", session_id: "s1", timestamp: 1.0))
    @store.save_server_event(make_server_event(name: "payment", level: "error", session_id: "s2", timestamp: 2.0))

    assert_equal ["signup"], @store.list_server_events(project: "app", name: "signup", limit: 10).map { |e| e["name"] }
    assert_equal ["payment"], @store.list_server_events(project: "app", level: "error", limit: 10).map { |e| e["name"] }
    assert_equal ["signup"], @store.list_server_events(project: "app", session_id: "s1", limit: 10).map { |e| e["name"] }
  end

  def test_list_server_events_filters_before_limiting
    # Interleave matching/non-matching events so a naive "limit-then-filter"
    # implementation returns fewer than `limit` rows even though enough
    # matches exist further into the range.
    30.times do |i|
      matching = i.even?
      @store.save_server_event(make_server_event(
        name: matching ? "match" : "skip",
        session_id: matching ? "sX" : "sY",
        timestamp: i.to_f
      ))
    end

    events = @store.list_server_events(project: "app", name: "match", limit: 10)
    assert_equal 10, events.size
    assert(events.all? { |e| e["name"] == "match" })
  end

  def test_list_server_events_scopes_by_project
    @store.save_server_event(make_server_event(project: "app", name: "a", timestamp: 1.0))
    @store.save_server_event(make_server_event(project: "other", name: "b", timestamp: 2.0))
    names = @store.list_server_events(project: "app", limit: 10).map { |e| e["name"] }
    assert_equal ["a"], names
  end

  # --- validation ------------------------------------------------------

  def test_save_occurrence_rejects_missing_fields
    assert_raises(ArgumentError) { @store.save_occurrence({"project" => "app"}) }
  end

  def test_save_server_event_rejects_missing_fields
    assert_raises(ArgumentError) { @store.save_server_event({"project" => "app"}) }
  end

  # --- linkage queries -------------------------------------------------

  def test_occurrences_for_session
    @store.save_occurrence(make_occurrence(fingerprint: "fp_s1", session_id: "sess_A", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_s2", session_id: "sess_A", timestamp: 2.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_s3", session_id: "sess_B", timestamp: 3.0))

    a = @store.occurrences_for_session("sess_A")
    assert_equal [1.0, 2.0], a.map { |o| o["timestamp"] }
    assert_equal ["sess_A"], a.map { |o| o["session_id"] }.uniq
  end

  def test_server_events_for_session
    @store.save_server_event(make_server_event(name: "a", session_id: "sess_A", timestamp: 1.0))
    @store.save_server_event(make_server_event(name: "b", session_id: "sess_B", timestamp: 2.0))
    names = @store.server_events_for_session("sess_A").map { |e| e["name"] }
    assert_equal ["a"], names
  end

  def test_session_ids_for_problem
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sx", session_id: "sess_A", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sx", session_id: "sess_A", timestamp: 2.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sx", session_id: "sess_B", timestamp: 3.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_sx", timestamp: 4.0)) # no session

    ids = @store.session_ids_for_problem("fp_sx")
    assert_equal %w[sess_A sess_B].sort, ids.sort
  end

  def test_list_problems_with_nil_project_returns_all
    @store.save_occurrence(make_occurrence(fingerprint: "fp_n1", project: "app"))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_n2", project: "other"))
    ids = @store.list_problems(project: nil, limit: 10).map { |p| p[:id] }
    assert_includes ids, "fp_n1"
    assert_includes ids, "fp_n2"
  end

  def test_list_server_events_with_nil_project_returns_all
    @store.save_server_event(make_server_event(project: "app", name: "a", timestamp: 1.0))
    @store.save_server_event(make_server_event(project: "other", name: "b", timestamp: 2.0))
    names = @store.list_server_events(project: nil, limit: 10).map { |e| e["name"] }
    assert_includes names, "a"
    assert_includes names, "b"
  end

  # --- save_occurrence session has_errors flag -----------------------------

  def test_save_occurrence_flags_session_has_errors
    @store.save_events(Sentiero::WindowRef.new("sess_he", "win_1"), [{"type" => 3, "timestamp" => 1.0}])
    @store.save_occurrence(make_occurrence(fingerprint: "fp_he", session_id: "sess_he", timestamp: 2.0))
    session = @store.get_session("sess_he")
    assert_equal true, session[:metadata] && session[:metadata]["has_errors"]
  end

  def test_save_occurrence_without_session_does_not_raise
    @store.save_occurrence(make_occurrence(fingerprint: "fp_nohe", timestamp: 1.0)) # no session_id, no session row
    refute_nil @store.get_problem("fp_nohe")
  end

  # --- GDPR erasure: delete_session removes session-scoped error records ----

  def test_delete_session_erases_session_scoped_error_records
    # an occurrence + event tied to sess_erase, plus a problem aggregate
    @store.save_occurrence(make_occurrence(fingerprint: "fp_er", session_id: "sess_erase", timestamp: 1.0))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_er", session_id: "sess_keep", timestamp: 2.0))
    @store.save_server_event(make_server_event(name: "e1", session_id: "sess_erase", timestamp: 1.0))
    @store.save_server_event(make_server_event(name: "e2", session_id: "sess_keep", timestamp: 2.0))

    @store.delete_session("sess_erase")

    # session-scoped personal data for sess_erase is gone...
    assert_empty @store.occurrences_for_session("sess_erase")
    assert_empty @store.server_events_for_session("sess_erase")
    # ...but other sessions' records remain...
    assert_equal 1, @store.occurrences_for_session("sess_keep").size
    assert_equal 1, @store.server_events_for_session("sess_keep").size
    # ...and the Problem aggregate is retained (count is not personal data)
    refute_nil @store.get_problem("fp_er")
  end

  def test_delete_session_without_session_scoped_records_is_safe
    @store.save_occurrence(make_occurrence(fingerprint: "fp_ns", timestamp: 1.0)) # no session_id
    @store.delete_session("sess_none") # must not raise
    refute_nil @store.get_problem("fp_ns")
  end

  # --- get_server_event by id -----------------------------------------------

  def test_get_server_event_by_id
    @store.save_server_event(make_server_event(name: "findme", session_id: "s1", timestamp: 5.0))
    stored = @store.list_server_events(project: "app", limit: 10).find { |e| e["name"] == "findme" }
    refute_nil stored["id"]
    fetched = @store.get_server_event(stored["id"])
    refute_nil fetched
    assert_equal "findme", fetched["name"]
    assert_equal "s1", fetched["session_id"]
  end

  def test_get_server_event_unknown_returns_nil
    assert_nil @store.get_server_event("does-not-exist")
  end

  def test_get_server_event_rejects_malformed_id
    assert_raises(ArgumentError) { @store.get_server_event("bad id!") }
  end

  # --- Retention: purge_older_than ages out error data ----------------------

  def test_purge_older_than_ages_out_error_data
    old = 1.0
    fresh = ::Time.now.to_f
    @store.save_occurrence(make_occurrence(fingerprint: "fp_purge_old", timestamp: old))
    @store.save_server_event(make_server_event(name: "old_evt", timestamp: old))
    @store.save_occurrence(make_occurrence(fingerprint: "fp_purge_new", timestamp: fresh))

    @store.purge_older_than(60) # drop anything older than 60s ago

    assert_nil @store.get_problem("fp_purge_old"), "stale problem should be purged"
    assert_empty @store.get_occurrences("fp_purge_old")
    assert_empty @store.list_server_events(project: nil, limit: 50).select { |e| e["name"] == "old_evt" }
    refute_nil @store.get_problem("fp_purge_new"), "fresh problem should survive"
  end
end
