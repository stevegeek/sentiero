# frozen_string_literal: true

require "rack"
require_relative "base_view"

module Sentiero
  module Web
    module Views
      # Serves both /custom-events branches; the template switches on #source.
      class EventsIndexView < BaseView
        def initialize(source: "server", events: nil, browser_rows: nil, level: nil,
          search: "", project: nil, projects: nil, since_param: nil, until_param: nil,
          level_mix: nil, page: nil, per_page: nil, has_next: nil, was_truncated: false,
          sibling: nil, single_name: nil, metric_keys: nil, metric_key: nil, metric_days: nil)
          super()
          @source = source
          @events = events
          @browser_rows = browser_rows
          @level = level
          @search = search
          @project = project
          @projects = projects
          @since_param = since_param
          @until_param = until_param
          @level_mix = level_mix
          @page = page
          @per_page = per_page
          @has_next = has_next
          @was_truncated = was_truncated
          @sibling = sibling
          @single_name = single_name
          @metric_keys = metric_keys
          @metric_key = metric_key
          @metric_days = metric_days
        end

        attr_reader :source, :events, :browser_rows, :level, :search, :project, :projects,
          :since_param, :until_param, :level_mix, :page, :per_page, :has_next, :was_truncated,
          :sibling, :single_name, :metric_keys, :metric_key, :metric_days

        def template = "events_index.html.erb"

        def volume_scaled? = !search.empty?

        def mix_max = level_mix.map { |_date, counts| counts.values.sum }.max

        def error_query(date)
          Rack::Utils.build_query({
            "level" => "error", "search" => search, "project" => project,
            "since" => date, "until" => date
          }.reject { |_key, value| value.to_s.empty? })
        end
      end
    end
  end
end
