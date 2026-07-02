# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class ProblemShowView < BaseView
        def initialize(problem:, occurrences:, session_ids:, session_summaries:, facets:, trend:)
          super()
          @problem = problem
          @occurrences = occurrences
          @session_ids = session_ids
          @session_summaries = session_summaries
          @facets = facets
          @trend = trend
        end

        attr_reader :problem, :occurrences, :session_ids, :session_summaries, :facets, :trend

        def template = "problem_show.html.erb"

        def replay_href(s)
          sid = s[:session_id]
          if s[:window_id]
            "#{h(base_path)}/sessions/#{h(sid)}/windows/#{h(s[:window_id])}"
          else
            "#{h(base_path)}/sessions/#{h(sid)}"
          end
        end

        def spark_max = trend[:series].map { |day| day[:count] }.max || 0

        def facet_groups
          [
            ["Top Request Paths", facets[:paths]],
            ["Environments", facets[:environments]],
            ["Browsers", facets[:browsers]]
          ]
        end

        def has_facets? = facets[:releases].any? || facet_groups.any? { |_title, rows| rows.any? }
      end
    end
  end
end
