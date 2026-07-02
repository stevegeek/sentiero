# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/funnel_view"

class FunnelViewTest < Minitest::Test
  def build(steps: [])
    Sentiero::Web::Views::FunnelView.new(
      tags: [], selected_steps: [], steps: steps,
      was_truncated: false, since: "", until_str: ""
    )
  end

  def test_format_gap_subsecond_is_ms
    assert_equal "450ms", build.format_gap(450)
  end

  def test_format_gap_over_a_second_uses_duration
    assert_equal "2s", build.format_gap(2000)
  end

  def test_step_one_sessions_reads_first_step
    assert_equal 12, build(steps: [{sessions: 12}, {sessions: 4}]).step_one_sessions
  end

  def test_dropped_is_difference_to_next_step
    assert_equal 8, build(steps: [{sessions: 12}, {sessions: 4}]).dropped(0)
  end
end
