# frozen_string_literal: true

require "test_helper"

class PurgeTest < Minitest::Test
  def setup
    Sentiero.reset_configuration!
    @store = Sentiero::Stores::Memory.new
    Sentiero.configuration.store = @store
  end

  def teardown
    Sentiero.reset_configuration!
  end

  def test_purge_expired_is_noop_when_retention_period_unset
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0}])
    sleep 0.05

    assert_nil Sentiero.purge_expired!
    assert_equal 1, @store.list_sessions(limit: 10).size
  end

  def test_purge_expired_deletes_sessions_older_than_retention_period
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0}])
    sleep 0.1
    Sentiero.configuration.retention_period = 0.01

    assert_equal 1, Sentiero.purge_expired!
    assert_equal [], @store.list_sessions(limit: 10)
  end

  def test_purge_expired_keeps_sessions_within_retention_period
    @store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0}])
    Sentiero.configuration.retention_period = 3600

    assert_equal 0, Sentiero.purge_expired!
    assert_equal 1, @store.list_sessions(limit: 10).size
  end

  # Regression: the base purge pages by offset so stale (oldest) sessions beyond
  # one scan-cap batch are still reached; a single first-batch scan would miss them.
  def test_purge_reaches_stale_sessions_beyond_the_scan_cap
    capped = Sentiero::Stores::Memory.new(
      limits: Sentiero::Store::Limits.new(analytics_max_scan_sessions: 2)
    )
    Sentiero.configuration.store = capped

    # Two oldest sessions are stale; three newer ones are within retention. With
    # a scan cap of 2, the newest batch contains none of the stale ones.
    capped.save_events(Sentiero::WindowRef.new("old1", "w"), [{"timestamp" => 1.0}])
    capped.save_events(Sentiero::WindowRef.new("old2", "w"), [{"timestamp" => 1.0}])
    sleep 0.1
    3.times { |i| capped.save_events(Sentiero::WindowRef.new("new#{i}", "w"), [{"timestamp" => 1.0}]) }
    Sentiero.configuration.retention_period = 0.05

    assert_equal 2, Sentiero.purge_expired!
    remaining = capped.list_sessions(limit: 10).map { |s| s[:session_id] }
    assert_equal %w[new0 new1 new2].sort, remaining.sort
  end
end
