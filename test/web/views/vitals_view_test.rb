# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/vitals_view"

class VitalsViewTest < Minitest::Test
  def build = Sentiero::Web::Views::VitalsView.new(pages: {}, was_truncated: false, since: "", until_str: "")

  def test_format_vital_cls_is_three_dp
    assert_equal "0.123", build.format_vital("CLS", 0.1234)
  end

  def test_format_vital_other_is_ms
    assert_equal "12 ms", build.format_vital("LCP", 12.4)
  end

  def test_dominant_rating_picks_highest_count
    assert_equal "good", build.dominant_rating({"good" => 9, "poor" => 2})
  end

  def test_rating_class_mapping
    assert_equal "badge-danger", build.rating_class("poor")
    assert_equal "badge-neutral", build.rating_class("unknown")
  end
end
