# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class ClientErrorShowView < BaseView
        def initialize(group:, was_truncated:)
          super()
          @group = group
          @was_truncated = was_truncated
        end

        attr_reader :group, :was_truncated

        def template = "client_error_show.html.erb"

        def status = group[:status]

        def changed_on
          changed_at = group.dig(:state, :changed_at)
          changed_at ? Time.at(changed_at.to_f).utc.strftime("%b %d, %Y %H:%M UTC") : nil
        end

        def facet_chips
          [
            ["Browsers", group[:browsers] || {}],
            ["Devices", group[:devices] || {}],
            ["Entry pages", group[:pages] || {}]
          ]
        end
      end
    end
  end
end
