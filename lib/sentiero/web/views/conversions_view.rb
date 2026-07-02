# frozen_string_literal: true

require_relative "base_view"

module Sentiero
  module Web
    module Views
      class ConversionsView < BaseView
        def initialize(tags:, selected_tag:, entry_pages:, referrers:, utm:, was_truncated:, since:, until_str:)
          super()
          @tags = tags
          @selected_tag = selected_tag
          @entry_pages = entry_pages
          @referrers = referrers
          @utm = utm
          @was_truncated = was_truncated
          @since = since
          @until_str = until_str
        end

        attr_reader :tags, :selected_tag, :entry_pages, :referrers, :utm, :was_truncated, :since, :until_str

        def template = "analytics_conversions.html.erb"

        def player_link(ex)
          "#{h(base_path)}/sessions/#{h(ex[:session_id].to_s)}/windows/#{h(ex[:window_id].to_s)}?t=#{ex[:offset_ms].to_i}"
        end

        def facets
          [
            ["Entry page", "entry page", entry_pages, nil],
            ["Referrer", "referrer", referrers, nil],
            ["UTM source", "UTM source", utm[:source], :utm],
            ["UTM medium", "UTM medium", utm[:medium], :utm],
            ["UTM campaign", "UTM campaign", utm[:campaign], :utm]
          ]
        end
      end
    end
  end
end
