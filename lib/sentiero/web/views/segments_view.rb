# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class SegmentsView < BaseView
        def initialize(filters:, browser_options:, device_options:, country_options:, sessions:, page:, per_page:, has_next:, was_truncated:, filter_query:)
          super()
          @filters = filters
          @browser_options = browser_options
          @device_options = device_options
          @country_options = country_options
          @sessions = sessions
          @page = page
          @per_page = per_page
          @has_next = has_next
          @was_truncated = was_truncated
          @filter_query = filter_query
        end

        attr_reader :filters, :browser_options, :device_options, :country_options, :sessions, :page, :per_page, :has_next, :was_truncated, :filter_query

        def template = "segments.html.erb"
      end
    end
  end
end
