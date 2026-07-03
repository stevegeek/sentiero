# frozen_string_literal: true

require "cgi/escape"
require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      class AnalyticsIndexView < BaseView
        BUCKET_COLORS = %w[#2563eb #7c3aed #db2777 #ea580c #16a34a].freeze

        def initialize(range_days:, allowed_ranges:, custom_range:, since:, until_str:, deltas:, stats:)
          super()
          @range_days = range_days
          @allowed_ranges = allowed_ranges
          @custom_range = custom_range
          @since = since
          @until_str = until_str
          @deltas = deltas
          @stats = stats
        end

        attr_reader :range_days, :allowed_ranges, :custom_range, :since, :until_str, :deltas, :stats

        def template = "analytics_index.html.erb"

        # Sessions/events deltas are % change; the error-free rate is percentage points.
        def render_delta(value, attr, unit)
          return "" if value.nil?
          arrow = (value >= 0) ? "&#9650;" : "&#9660;"
          color = (value >= 0) ? "#16a34a" : "#dc2626"
          %(<span class="normal-case tracking-normal tabular-nums" style="color:#{color}" data-#{attr}="#{value}" title="vs previous period">#{arrow} #{value.abs}#{unit}</span>)
        end

        # An active custom range is carried into the range-scoped cross-links
        # (the open-problems count is all-time, so its link stays unscoped).
        def range_qs
          return "" unless custom_range

          "&" + Rack::Utils.build_query(range_pairs)
        end

        def series = stats[:events_per_day_series] || []
        def max_events = series.map { |d| d[:event_count] }.max || 0
        def max_sessions = series.map { |d| d[:session_count] }.max || 0

        def distributions
          base = [
            ["Browsers", stats[:browser_distribution], "No browser data."],
            ["Devices", stats[:device_distribution], "No device data."]
          ]
          # Location cards only render when geo capture is on and resolving,
          # so feature-off deployments don't see two permanently empty cards.
          {"Countries" => :country_distribution, "Cities" => :city_distribution}.each do |label, key|
            dist = stats[key] || {}
            base << [label, dist, ""] unless dist.empty?
          end
          base
        end

        def buckets = stats[:session_duration_buckets] || {}
        def bucket_total = buckets.values.sum
        def bucket_colors = BUCKET_COLORS
        def donut_radius = 42
        def donut_circumference = 2 * Math::PI * donut_radius

        def custom_tags = stats[:custom_event_tags] || {}
        def browser_tags = stats[:browser_event_tags] || {}
        def tag_series = stats[:custom_event_tag_series] || {}

        def tag_href(tag)
          q = "search=#{CGI.escape(tag)}"
          q = "source=browser&#{q}" if browser_tags.key?(tag)
          "#{base_path}/custom-events?#{q}"
        end

        def tag_day_series(tag) = tag_series[tag] || []
        def tag_series_max(tag) = tag_day_series(tag).map { |day| day[:count] }.max.to_i

        def seg_href(row)
          "#{base_path}/analytics/segments?" + Rack::Utils.build_query({"url_pattern" => row[:url], "has_errors" => "true"})
        end

        def err_pct(row) = (row[:count].to_i > 0) ? (row[:error_count].to_f / row[:count] * 100).round : 0

        def nav_sections(nav)
          [["Internal destinations", nav[:internal] || []], ["External destinations", nav[:external] || []]]
        end
      end
    end
  end
end
