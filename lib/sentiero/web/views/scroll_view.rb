# frozen_string_literal: true

require_relative "analyzer_view"

module Sentiero
  module Web
    module Views
      class ScrollView < AnalyzerView
        def template = "analytics_scroll.html.erb"

        def sorted_pages = pages.sort_by { |url, page| [-page[:session_count], url] }

        def svg_width = 320
        def svg_height = 140
        def bar_gap = 12
        def axis_y = svg_height - 24
        def chart_top = 12
        def bar_width = (svg_width - bar_gap * 5) / 4
        def max_count(dist) = [dist.values.max, 1].max
      end
    end
  end
end
