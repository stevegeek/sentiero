# frozen_string_literal: true

module Sentiero
  module Rails
    module Helpers
      module ScriptTagHelper
        def sentiero_script_tag(events_url: nil, recorder_url: nil)
          events_url ||= Sentiero::Rails.configuration.events_url
          Sentiero::Web::ScriptTag.render(events_url: events_url, recorder_url: recorder_url).html_safe
        end
      end
    end
  end
end
