# frozen_string_literal: true

require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      class PageReportView < BaseView
        def initialize(report:, urls:, selected_url:, was_truncated:, since:, until_str:)
          super()
          @report = report
          @urls = urls
          @selected_url = selected_url
          @was_truncated = was_truncated
          @since = since
          @until_str = until_str
        end

        attr_reader :report, :urls, :selected_url, :was_truncated, :since, :until_str

        def template = "analytics_page.html.erb"

        def secs(ms) = ms ? "#{(ms / 1000.0).round(1)}s" : "&mdash;"

        def pct(rate) = "#{(rate * 100).round(1)}%"

        def heatmap_href
          q = {}
          q["url"] = selected_url if selected_url && !selected_url.to_s.empty?
          q.merge!(range_pairs)
          "#{base_path}/analytics/heatmap" + (q.empty? ? "" : "?" + Rack::Utils.build_query(q))
        end

        def time_on_page = report[:time_on_page]
        def entry_exit = report[:entry_exit]
        def scroll = report[:scroll]
        def forms = report[:forms]
        def frustration = report[:frustration]
      end
    end
  end
end
