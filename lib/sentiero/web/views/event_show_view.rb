# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class EventShowView < BaseView
        def initialize(event:)
          super()
          @event = event
        end

        attr_reader :event

        def template = "event_show.html.erb"
      end
    end
  end
end
