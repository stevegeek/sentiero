# frozen_string_literal: true

require "test_helper"

class ErasureTest < Minitest::Test
  def setup
    Sentiero.reset_configuration!
    @store = Sentiero::Stores::Memory.new
    Sentiero.configure { |c| c.store = @store }
  end

  def teardown
    Sentiero.reset_configuration!
  end

  def save(session_id)
    @store.save_events(Sentiero::WindowRef.new(session_id, "w1"), [{"timestamp" => 1.0}])
  end

  # --- erase_sessions ---

  def test_erase_sessions_removes_only_the_given_ids
    save("keep")
    save("drop-1")
    save("drop-2")

    deleted = Sentiero.erase_sessions(["drop-1", "drop-2"])

    assert_equal 2, deleted
    assert_nil @store.get_session("drop-1")
    assert_nil @store.get_session("drop-2")
    refute_nil @store.get_session("keep")
  end

  def test_erase_sessions_returns_count_of_existing_sessions_deleted
    save("present")

    assert_equal 1, Sentiero.erase_sessions(["present", "absent"])
  end

  def test_erase_sessions_ignores_nonexistent_ids
    deleted = Sentiero.erase_sessions(["never-existed"])
    assert_equal 0, deleted
  end

  def test_erase_sessions_with_empty_list_does_nothing
    save("keep")

    assert_equal 0, Sentiero.erase_sessions([])
    refute_nil @store.get_session("keep")
  end

  def test_erase_sessions_rejects_invalid_id
    assert_raises(ArgumentError) { Sentiero.erase_sessions(["bad id!"]) }
  end

  # --- erase_where ---

  def test_erase_where_removes_only_in_range_sessions
    save("before")
    sleep 0.05
    from = Time.now
    sleep 0.05
    save("inside")
    sleep 0.05
    to = Time.now
    sleep 0.05
    save("after")

    deleted = Sentiero.erase_where(since: from, until_time: to)

    assert_equal 1, deleted
    assert_nil @store.get_session("inside")
    refute_nil @store.get_session("before")
    refute_nil @store.get_session("after")
  end

  def test_erase_where_with_only_since_removes_newer_sessions
    save("old")
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    save("new")

    deleted = Sentiero.erase_where(since: cutoff)

    assert_equal 1, deleted
    assert_nil @store.get_session("new")
    refute_nil @store.get_session("old")
  end

  def test_erase_where_with_only_until_time_removes_older_sessions
    save("old")
    sleep 0.05
    cutoff = Time.now
    sleep 0.05
    save("new")

    deleted = Sentiero.erase_where(until_time: cutoff)

    assert_equal 1, deleted
    assert_nil @store.get_session("old")
    refute_nil @store.get_session("new")
  end

  def test_erase_where_requires_at_least_one_bound
    assert_raises(ArgumentError) { Sentiero.erase_where }
  end

  def test_erase_where_rejects_inverted_range
    now = Time.now
    assert_raises(ArgumentError) { Sentiero.erase_where(since: now + 60, until_time: now) }
  end

  def test_erase_where_returns_zero_when_nothing_matches
    save("recent")

    assert_equal 0, Sentiero.erase_where(until_time: Time.now - 3600)
    refute_nil @store.get_session("recent")
  end

  def test_erase_where_pages_past_the_scan_cap_in_one_call
    @store.limits = Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
    cutoff = Time.now - 3600
    5.times { |i| save("s#{i}") }

    deleted = Sentiero.erase_where(since: cutoff)

    assert_equal 5, deleted
    5.times { |i| assert_nil @store.get_session("s#{i}") }
  end
end
