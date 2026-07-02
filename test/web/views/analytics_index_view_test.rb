# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/analytics_index_view"

class AnalyticsIndexViewTest < Minitest::Test
  def build(stats: {}, custom_range: false, since: "", until_str: "")
    Sentiero::Web::Views::AnalyticsIndexView.new(
      range_days: 7, allowed_ranges: [7, 30], custom_range: custom_range,
      since: since, until_str: until_str, deltas: {}, stats: stats
    )
  end

  def test_render_delta_nil_is_blank
    assert_equal "", build.render_delta(nil, "sessions", "%")
  end

  def test_render_delta_positive_has_up_arrow
    html = build.render_delta(5, "sessions", "%")
    assert_includes html, "&#9650;"
    assert_includes html, "5%"
  end

  def test_err_pct_zero_when_no_count
    assert_equal 0, build.err_pct({count: 0, error_count: 3})
  end

  def test_range_qs_blank_without_custom_range
    assert_equal "", build.range_qs
  end
end
