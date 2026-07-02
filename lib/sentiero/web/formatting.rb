# frozen_string_literal: true

require_relative "../user_agent"

module Sentiero
  module Web
    # Small presentation formatters shared by the Rack apps and the view layer.
    module Formatting
      def parse_device(user_agent)
        Sentiero::UserAgent.device(user_agent)
      end

      def parse_browser(user_agent)
        Sentiero::UserAgent.browser(user_agent)
      end

      # CLS is a unitless ratio (3 decimals); the other Web Vitals are millisecond durations.
      def format_vital(metric, value)
        (metric == "CLS") ? format("%.3f", value) : "#{value.round} ms"
      end

      def format_duration(first_event_at, last_event_at)
        return "N/A" unless first_event_at && last_event_at

        # Event timestamps are in milliseconds
        total_ms = (last_event_at - first_event_at).abs
        total_seconds = (total_ms / 1000.0).round

        if total_seconds < 60
          "#{total_seconds}s"
        elsif total_seconds < 3600
          minutes = total_seconds / 60
          seconds = total_seconds % 60
          (seconds > 0) ? "#{minutes}m #{seconds}s" : "#{minutes}m"
        else
          hours = total_seconds / 3600
          minutes = (total_seconds % 3600) / 60
          (minutes > 0) ? "#{hours}h #{minutes}m" : "#{hours}h"
        end
      end
    end
  end
end
