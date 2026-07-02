# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/engagement_view"

class EngagementViewTest < Minitest::Test
  def build(sessions: [], sort: "score", distribution: {})
    Sentiero::Web::Views::EngagementView.new(
      sessions: sessions, distribution: distribution, scanned: 0,
      was_truncated: false, sort: sort, since: "", until_str: ""
    )
  end

  def test_sorted_sessions_default_keeps_order
    rows = [{session_id: "a"}, {session_id: "b"}]
    assert_equal rows, build(sessions: rows).sorted_sessions
  end

  def test_sorted_sessions_by_duration
    rows = [{session_id: "a", duration_ms: 10}, {session_id: "b", duration_ms: 99}]
    assert_equal "b", build(sessions: rows, sort: "duration").sorted_sessions.first[:session_id]
  end

  def test_badge_class_thresholds
    v = build
    assert_equal "badge badge-danger", v.badge_class(60)
    assert_equal "badge badge-warning", v.badge_class(30)
    assert_equal "text-gray-400", v.badge_class(0)
  end

  def test_chips_emits_present_signals_only
    chips = build.chips({rage_clicks: 2, dead_clicks: 0, quick_bounce: true})
    assert_includes chips, "rage&times;2"
    assert_includes chips, "bounce"
    refute(chips.any? { |c| c.include?("dead") })
  end
end
