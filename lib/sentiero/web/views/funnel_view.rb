# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class FunnelView < BaseView
        def initialize(tags:, selected_steps:, steps:, was_truncated:, since:, until_str:)
          super()
          @tags = tags
          @selected_steps = selected_steps
          @steps = steps
          @was_truncated = was_truncated
          @since = since
          @until_str = until_str
        end

        attr_reader :tags, :selected_steps, :steps, :was_truncated, :since, :until_str

        def template = "analytics_funnel.html.erb"

        def format_gap(ms) = (ms < 1000) ? "#{ms.round}ms" : format_duration(0, ms)

        def step_one_sessions = @step_one_sessions ||= steps.first&.fetch(:sessions).to_i

        def next_step(i) = steps[i + 1]

        def dropped(i)
          n = next_step(i)
          n ? steps[i][:sessions] - n[:sessions] : 0
        end
      end
    end
  end
end
