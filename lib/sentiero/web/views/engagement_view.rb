# frozen_string_literal: true

require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      class EngagementView < BaseView
        def initialize(sessions:, distribution:, scanned:, was_truncated:, sort:, since:, until_str:)
          super()
          @sessions = sessions
          @distribution = distribution
          @scanned = scanned
          @was_truncated = was_truncated
          @sort = sort
          @since = since
          @until_str = until_str
        end

        attr_reader :sessions, :distribution, :scanned, :was_truncated, :sort, :since, :until_str

        def template = "analytics_engagement.html.erb"

        def sorted_sessions
          (sort == "duration") ? sessions.sort_by { |row| [-row[:duration_ms], row[:session_id]] } : sessions
        end

        def sort_link(column)
          "#{base_path}/analytics/engagement?" + Rack::Utils.build_query(range_pairs.merge("sort" => column))
        end

        def svg_width = 360
        def svg_height = 140
        def bar_gap = 12
        def axis_y = svg_height - 24
        def chart_top = 12
        def bin_count = distribution.size
        def bar_width = (svg_width - bar_gap * (bin_count + 1)) / bin_count
        def max_count = [distribution.values.max, 1].max
        def bar_h(count) = (count.to_f / max_count * (axis_y - chart_top)).round(1)
        def bar_x(i) = bar_gap + i * (bar_width + bar_gap)
        def bar_y(count) = (axis_y - bar_h(count)).round(1)

        def badge_class(score)
          if score >= 60 then "badge badge-danger"
          elsif score >= 30 then "badge badge-warning"
          else "text-gray-400"
          end
        end

        def chips(signals)
          chips = []
          chips << "rage&times;#{signals[:rage_clicks]}" if signals[:rage_clicks].to_i > 0
          chips << "dead&times;#{signals[:dead_clicks]}" if signals[:dead_clicks].to_i > 0
          chips << "churn&times;#{signals[:nav_churn]}" if signals[:nav_churn].to_i > 0
          chips << "idle #{(signals[:idle_ratio].to_f * 100).round}%" if signals[:idle_ratio].to_f > 0
          chips << "thrash&times;#{signals[:thrashing_scroll]}" if signals[:thrashing_scroll].to_i > 0
          chips << "bounce" if signals[:quick_bounce]
          chips << "refill&times;#{signals[:form_refills]}" if signals[:form_refills].to_i > 0
          chips << "err-abandon" if signals[:error_abandonment]
          chips
        end
      end
    end
  end
end
