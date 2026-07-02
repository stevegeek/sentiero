# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/events_index_view"

class EventsIndexViewTest < Minitest::Test
  def test_source_defaults_to_server
    assert_equal "server", Sentiero::Web::Views::EventsIndexView.new.source
  end

  def test_volume_scaled_when_search_present
    refute Sentiero::Web::Views::EventsIndexView.new(search: "").volume_scaled?
    assert Sentiero::Web::Views::EventsIndexView.new(search: "x").volume_scaled?
  end

  def test_mix_max_sums_per_day_counts
    view = Sentiero::Web::Views::EventsIndexView.new(level_mix: {"d1" => {a: 1, b: 2}, "d2" => {a: 1}})
    assert_equal 3, view.mix_max
  end
end
