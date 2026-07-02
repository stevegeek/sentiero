# frozen_string_literal: true

require_relative "analyzer_view"

module Sentiero
  module Web
    module Views
      class VitalsView < AnalyzerView
        RATING_COLORS = {"good" => "#16a34a", "needs-improvement" => "#d97706", "poor" => "#dc2626"}.freeze

        def template = "analytics_vitals.html.erb"

        def sorted_pages = pages.sort_by { |url, page| [-page[:sample_count], url] }

        def dominant_rating(ratings) = ratings.max_by { |rating, count| [count, rating] }&.first

        def rating_class(rating)
          case rating
          when "good" then "badge-success"
          when "needs-improvement" then "badge-warning"
          when "poor" then "badge-danger"
          else "badge-neutral"
          end
        end

        def rating_colors = RATING_COLORS

        def page_rating_mix(page)
          rating_colors.keys.to_h do |rating|
            [rating, page[:metrics].sum { |_metric, m| m[:ratings].fetch(rating, 0) }]
          end
        end

        def slowest(page)
          %w[LCP INP CLS].each do |metric|
            worst = page[:metrics].dig(metric, :worst)
            return worst if worst
          end
          page[:metrics].each_value { |m| return m[:worst] if m[:worst] }
          nil
        end
      end
    end
  end
end
