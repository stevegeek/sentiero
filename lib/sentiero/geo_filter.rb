# frozen_string_literal: true

module Sentiero
  module GeoFilter
    module_function

    def by_country(sessions, country_code)
      sessions.select { |s| s.dig(:geo_location, :country_code) == country_code }
    end

    def by_city(sessions, city)
      sessions.select { |s| s.dig(:geo_location, :city) == city }
    end

    def by_region(sessions, region)
      sessions.select { |s| s.dig(:geo_location, :region) == region }
    end

    def by_timezone(sessions, timezone)
      sessions.select { |s| s.dig(:geo_location, :timezone) == timezone }
    end

    # Filter sessions within a radius of a point using the Haversine formula.
    def within_radius(sessions, lat:, lng:, radius_km:)
      sessions.select do |s|
        geo = s[:geo_location]
        next false unless geo && geo[:latitude] && geo[:longitude]

        distance_km(lat, lng, geo[:latitude], geo[:longitude]) <= radius_km
      end
    end

    # Haversine distance in km between two lat/lng points.
    def distance_km(lat1, lng1, lat2, lng2)
      r = 6371.0 # Earth radius in km

      dlat = to_rad(lat2 - lat1)
      dlng = to_rad(lng2 - lng1)

      a = Math.sin(dlat / 2)**2 +
          Math.cos(to_rad(lat1)) * Math.cos(to_rad(lat2)) * Math.sin(dlng / 2)**2

      2 * r * Math.asin(Math.sqrt(a))
    end

    def to_rad(degrees)
      degrees * Math::PI / 180.0
    end

    private_class_method :distance_km, :to_rad
  end
end
