# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      # Serves both /issues branches; the template switches on #source.
      class ErrorsIndexView < BaseView
        def initialize(source:, problems: nil, groups: nil, sibling: nil, status: nil,
          search: "", sort_by: nil, since_param: nil, until_param: nil, new_since: nil,
          page: nil, per_page: nil, has_next: nil, was_truncated: false)
          super()
          @source = source
          @problems = problems
          @groups = groups
          @sibling = sibling
          @status = status
          @search = search
          @sort_by = sort_by
          @since_param = since_param
          @until_param = until_param
          @new_since = new_since
          @page = page
          @per_page = per_page
          @has_next = has_next
          @was_truncated = was_truncated
        end

        attr_reader :source, :problems, :groups, :sibling, :status, :search, :sort_by,
          :since_param, :until_param, :new_since, :page, :per_page, :has_next, :was_truncated

        def template = "errors_index.html.erb"
      end
    end
  end
end
