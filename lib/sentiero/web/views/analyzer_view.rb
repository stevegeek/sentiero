# frozen_string_literal: true

require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      class AnalyzerView < BaseView
        def initialize(pages:, was_truncated:, since:, until_str:)
          super()
          @pages = pages
          @was_truncated = was_truncated
          @since = since
          @until_str = until_str
        end

        attr_reader :pages, :was_truncated, :since, :until_str

        def page_report_href(url)
          q = {"url" => url}.merge(range_pairs)
          "#{base_path}/analytics/page?" + Rack::Utils.build_query(q)
        end
      end
    end
  end
end
