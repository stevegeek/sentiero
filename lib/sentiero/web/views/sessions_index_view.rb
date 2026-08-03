# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class SessionsIndexView < BaseView
        def initialize(sessions:, page:, per_page:, has_next:, search:, sort_by:, since:, until_param:, has_errors:,
          min_duration: "", min_events: "")
          super()
          @sessions = sessions
          @page = page
          @per_page = per_page
          @has_next = has_next
          @search = search
          @sort_by = sort_by
          @since = since
          @until_param = until_param
          @has_errors = has_errors
          @min_duration = min_duration
          @min_events = min_events
        end

        attr_reader :sessions, :page, :per_page, :has_next, :search, :sort_by, :since, :until_param, :has_errors,
          :min_duration, :min_events

        def template = "sessions_index.html.erb"
      end
    end
  end
end
