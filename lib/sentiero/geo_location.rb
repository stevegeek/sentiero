# frozen_string_literal: true

module Sentiero
  GeoLocation = Struct.new(
    :country_code,  # ISO 3166-1 alpha-2 ("US", "DE", etc.)
    :country_name,  # Full name ("United States") — populated by MaxMind, nil for Cloudflare
    :city,
    :region,
    :region_code,
    :postal_code,
    :timezone,      # IANA timezone ("America/Los_Angeles")
    :latitude,      # Float
    :longitude,     # Float
    :ip,            # Client IP — nil if capture_ip is false
    keyword_init: true
  ) do
    def to_h
      super.compact
    end
  end
end
