# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class ExportView < BaseView
        def initialize(shareable_replays:, since:, until_str:, datasets:)
          super()
          @shareable_replays = shareable_replays
          @since = since
          @until_str = until_str
          @datasets = datasets
        end

        attr_reader :shareable_replays, :since, :until_str, :datasets

        def template = "export_index.html.erb"
      end
    end
  end
end
