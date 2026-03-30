# frozen_string_literal: true

module Sentiero
  class SessionMetadata
    attr_accessor :geo_location, :user_agent, :referrer, :started_at

    def initialize(geo_location: nil, user_agent: nil, referrer: nil)
      @geo_location = geo_location
      @user_agent = user_agent
      @referrer = referrer
      @started_at = Time.now.utc
    end

    def to_h
      {
        geo_location: geo_location&.to_h,
        user_agent: user_agent,
        referrer: referrer,
        started_at: started_at.iso8601
      }.compact
    end
  end
end
