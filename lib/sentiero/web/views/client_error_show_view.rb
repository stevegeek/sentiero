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

        def facet_chips
          [
            ["Browsers", group[:browsers] || {}],
            ["Devices", group[:devices] || {}],
            ["Pages", group[:pages] || {}]
          ]
        end
      end
    end
  end
end
