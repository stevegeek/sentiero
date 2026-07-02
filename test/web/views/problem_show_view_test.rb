# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/problem_show_view"

class ProblemShowViewTest < Minitest::Test
  def build(facets: {}, trend: {series: []})
    Sentiero::Web::Views::ProblemShowView.new(
      problem: {}, occurrences: [], session_ids: [], session_summaries: [],
      facets: facets, trend: trend
    )
  end

  def test_spark_max_handles_empty_series
    assert_equal 0, build.spark_max
  end

  def test_replay_href_with_window
    v = build
    v.base_path = "/mnt"
    assert_equal "/mnt/sessions/s1/windows/w1", v.replay_href({session_id: "s1", window_id: "w1"})
  end

  def test_has_facets_false_when_empty
    refute build(facets: {paths: [], environments: [], browsers: [], releases: []}).has_facets?
  end
end
