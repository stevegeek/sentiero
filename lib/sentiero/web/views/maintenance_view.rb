# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class MaintenanceView < BaseView
        def initialize(retention_period:, purged: nil, error: nil)
          super()
          @retention_period = retention_period
          @purged = purged
          @error = error
        end

        attr_reader :retention_period, :purged, :error

        def retention_days
          days = (retention_period / 86_400.0).round(1)
          (days % 1 == 0) ? days.to_i : days
        end

        def template = "maintenance.html.erb"
      end
    end
  end
end
