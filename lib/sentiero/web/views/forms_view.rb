# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class FormsView < BaseView
        def initialize(sessions_started:, sessions_completed:, completion_rate:, total_submits:, fields:, drop_off_fields:, was_truncated:, since:, until_str:)
          super()
          @sessions_started = sessions_started
          @sessions_completed = sessions_completed
          @completion_rate = completion_rate
          @total_submits = total_submits
          @fields = fields
          @drop_off_fields = drop_off_fields
          @was_truncated = was_truncated
          @since = since
          @until_str = until_str
        end

        attr_reader :sessions_started, :sessions_completed, :completion_rate, :total_submits, :fields, :drop_off_fields, :was_truncated, :since, :until_str

        def template = "forms.html.erb"
      end
    end
  end
end
