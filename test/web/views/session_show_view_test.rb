# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/session_show_view"

class SessionShowViewTest < Minitest::Test
  def build(session:, window_id: "w", server_activity: nil, base_path: "")
    v = Sentiero::Web::Views::SessionShowView.new(
      session: session, session_id: "s", window_id: window_id,
      shareable_replays: false, server_activity: server_activity
    )
    v.base_path = base_path
    v
  end

  def test_total_events_sums_windows
    v = build(session: {windows: [{event_count: 3}, {event_count: 4}], metadata: {}})
    assert_equal 7, v.total_events
  end

  def test_multi_window_predicate
    refute build(session: {windows: [{window_id: "w"}], metadata: {}}).multi_window?
    assert build(session: {windows: [{window_id: "w"}, {window_id: "w2"}], metadata: {}}).multi_window?
  end

  def test_custom_keys_excludes_known
    v = build(session: {windows: [], metadata: {"url" => "x", "foo" => "bar"}})
    assert_equal ["foo"], v.custom_keys
  end

  # ── tabs (window partition / overflow) ──

  def test_tabs_numbers_windows_by_last_activity
    v = build(session: {windows: [
      {window_id: "b", last_event_at: 200},
      {window_id: "a", last_event_at: 100}
    ]})
    all = v.tabs[:all]
    assert_equal ["a", "b"], all.map { |t| t[:window][:window_id] }
    assert_equal [1, 2], all.map { |t| t[:tab_num] }
    assert_empty v.tabs[:overflow]
  end

  def test_tabs_keeps_active_window_visible_in_overflow
    windows = (1..8).map { |i| {window_id: "w#{i}", last_event_at: i} }
    v = build(session: {windows: windows}, window_id: "w1") # oldest, would be hidden
    visible_ids = v.tabs[:visible].map { |t| t[:window][:window_id] }
    assert_includes visible_ids, "w1"
    assert_equal 4, v.tabs[:visible].size # MAX_VISIBLE_TABS - 1 slots
    assert_equal windows.size, v.tabs[:all].size
  end

  # ── server_markers (player-relative geometry) ──

  def test_server_markers_empty_without_activity
    assert_empty build(session: {windows: []}).server_markers
  end

  def test_server_markers_convert_seconds_and_clamp
    session = {windows: [{window_id: "w", first_event_at: 10_000.0}]}
    activity = [
      {kind: "event", timestamp: 11.0, event: {"id" => "e1", "name" => "checkout", "level" => "info"}},
      {kind: "exception", timestamp: 5.0, occurrence: {"exception_class" => "Boom", "message" => "oops", "fingerprint" => "fp"}}
    ]
    markers = build(session: session, server_activity: activity, base_path: "/m").server_markers

    assert_equal [0, 1000], markers.map { |m| m[:offset_ms] } # sorted, negative clamped
    exc = markers.find { |m| m[:kind] == "exception" }
    assert_equal "Boom: oops", exc[:label]
    assert_equal "/m/issues/fp", exc[:href]
    evt = markers.find { |m| m[:kind] == "event" }
    assert_equal "/m/custom-events/e1", evt[:href]
  end
end
