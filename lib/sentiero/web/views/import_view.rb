# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class ImportView < BaseView
        def template = "import.html.erb"
      end
    end
  end
end
