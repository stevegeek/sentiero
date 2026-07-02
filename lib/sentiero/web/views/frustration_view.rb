# frozen_string_literal: true

require_relative "analyzer_view"

module Sentiero
  module Web
    module Views
      class FrustrationView < AnalyzerView
        def template = "analytics_frustration.html.erb"

        def sorted_pages = pages.sort_by { |url, page| [-(page[:rage_count] + page[:dead_count]), url] }
      end
    end
  end
end
