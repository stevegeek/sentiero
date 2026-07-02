# frozen_string_literal: true

require "test_helper"
require "sentiero/web/dashboard_app"

class ThreadSafetyTest < Minitest::Test
  def setup
    @store = Sentiero::Stores::Memory.new
    Sentiero.configure do |c|
      c.store = @store
    end
  end

  def teardown
    Sentiero.reset_configuration!
  end

  # ---------------------------------------------------------------------------
  # 1. delete_session race condition
  #
  # delete_session performs two unsynchronized operations on internal state.
  # A concurrent save_events can interleave between them, leaving the store
  # in an inconsistent state where events exist but the session is invisible
  # via get_session or list_sessions.
  # ---------------------------------------------------------------------------
  def test_delete_session_concurrent_with_save_stays_consistent
    inconsistencies = 0
    iterations = 200

    iterations.times do
      store = Sentiero::Stores::Memory.new
      session_id = "s1"

      store.save_events(Sentiero::WindowRef.new(session_id, "w1"), [{"type" => "seed", "timestamp" => 1.0}])

      t1 = Thread.new do
        store.delete_session(session_id)
      end

      t2 = Thread.new do
        store.save_events(Sentiero::WindowRef.new(session_id, "w2"), [{"type" => "concurrent", "timestamp" => 2.0}])
      end

      t1.join
      t2.join

      # Public API consistency: if events exist, the session must be visible
      events = store.get_events(Sentiero::WindowRef.new(session_id, "w2"))
      session = store.get_session(session_id)

      if !events.empty? && session.nil?
        inconsistencies += 1
      end

      # list_sessions must not reference sessions that get_session can't find
      store.list_sessions(limit: 10).each do |s|
        if store.get_session(s[:session_id]).nil?
          inconsistencies += 1
        end
      end
    end

    assert_equal 0, inconsistencies,
      "Race condition detected in delete_session: store became inconsistent " \
      "(events exist but session invisible, or listed but not retrievable) " \
      "#{inconsistencies} times out of #{iterations} iterations."
  end

  # ---------------------------------------------------------------------------
  # 2. delete_window race condition
  #
  # delete_window for the last window triggers session cleanup. A concurrent
  # save_events can add a new window between the empty check and the cleanup,
  # causing data loss or inconsistency.
  # ---------------------------------------------------------------------------
  def test_delete_window_concurrent_with_save_stays_consistent
    inconsistencies = 0
    iterations = 200

    iterations.times do
      store = Sentiero::Stores::Memory.new
      session_id = "s1"

      store.save_events(Sentiero::WindowRef.new(session_id, "w1"), [{"type" => "seed", "timestamp" => 1.0}])

      t1 = Thread.new do
        store.delete_window(Sentiero::WindowRef.new(session_id, "w1"))
      end

      t2 = Thread.new do
        store.save_events(Sentiero::WindowRef.new(session_id, "w2"), [{"type" => "concurrent", "timestamp" => 2.0}])
      end

      t1.join
      t2.join

      # If save_events for w2 succeeded, those events should be retrievable
      # and the session should be visible
      events_w2 = store.get_events(Sentiero::WindowRef.new(session_id, "w2"))
      session = store.get_session(session_id)

      if !events_w2.empty? && session.nil?
        inconsistencies += 1
      end

      # list_sessions must stay consistent with get_session
      store.list_sessions(limit: 10).each do |s|
        if store.get_session(s[:session_id]).nil?
          inconsistencies += 1
        end
      end
    end

    assert_equal 0, inconsistencies,
      "Race condition detected in delete_window: store became inconsistent " \
      "#{inconsistencies} times out of #{iterations} iterations."
  end

  # ---------------------------------------------------------------------------
  # 3. Template cache returns the same ERB instance on repeated calls
  #
  # compiled_template is idempotent,  concurrent compilation of the same
  # template just means one extra File.read, but the cache should return
  # the same object on subsequent calls (Concurrent::Map#compute_if_absent
  # guarantees this).
  # ---------------------------------------------------------------------------
  def test_template_cache_returns_same_object
    # Clear cached entries but keep the Concurrent::Map intact. The cache is a
    # single shared constant on BaseView, so all view classes share it.
    cache = Sentiero::Web::Views::BaseView::TEMPLATE_CACHE
    cache.clear

    first = Sentiero::Web::Views::BaseView.compiled_template("dashboard.html.erb")
    second = Sentiero::Web::Views::BaseView.compiled_template("dashboard.html.erb")

    assert_same first, second,
      "compiled_template should return the cached ERB instance on repeated calls"
  end
end
