# frozen_string_literal: true

require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      class HeatmapView < BaseView
        def initialize(urls:, selected_url:, was_truncated:, config_json:, since:, until_str:)
          super()
          @urls = urls
          @selected_url = selected_url
          @was_truncated = was_truncated
          @config_json = config_json
          @since = since
          @until_str = until_str
        end

        attr_reader :urls, :selected_url, :was_truncated, :config_json, :since, :until_str

        def template = "heatmap.html.erb"

        # Query holds server-side strings only; escaped at the h.call sink.
        def page_report_href
          q = {}
          q["url"] = selected_url if selected_url && !selected_url.to_s.empty?
          q.merge!(range_pairs)
          "#{base_path}/analytics/page" + (q.empty? ? "" : "?" + Rack::Utils.build_query(q))
        end
      end
    end
  end
end
