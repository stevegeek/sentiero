# frozen_string_literal: true

module Sentiero
  # User-Agent classifier into coarse buckets — good enough for distribution
  # charts, not for precise version detection.
  module UserAgent
    module_function

    def device(user_agent)
      return if !user_agent || user_agent.empty?
      if user_agent.match?(/Tablet|iPad/i)
        "Tablet"
      elsif user_agent.match?(/Mobile|Android|iPhone/i)
        "Mobile"
      else
        "Desktop"
      end
    end

    def browser(user_agent)
      return if !user_agent || user_agent.empty?
      case user_agent
      when /Edg\//i then "Edge"
      when /OPR\//i, /Opera/i then "Opera"
      when /Chrome\//i then "Chrome"
      when /Safari\//i then "Safari"
      when /Firefox\//i then "Firefox"
      else "Other"
      end
    end
  end
end
