# frozen_string_literal: true

module Sentiero
  module GeoResolvers
    class MaxmindResolver
      include GeoResolver

      def initialize(database_path)
        raise Sentiero::Error, "MaxMind database path is required" unless database_path
        raise Sentiero::Error, "MaxMind database not found: #{database_path}" unless File.exist?(database_path)

        self.class.require_maxmind!
        @reader = MaxMind::GeoIP2::Reader.new(database: database_path)
      end

      def resolve(request)
        ip = request.ip
        return nil unless ip

        record = @reader.city(ip)

        GeoLocation.new(
          country_code: record.country&.iso_code,
          country_name: record.country&.name,
          city:         record.city&.name,
          region:       record.most_specific_subdivision&.name,
          region_code:  record.most_specific_subdivision&.iso_code,
          postal_code:  record.postal&.code,
          timezone:     record.location&.time_zone,
          latitude:     record.location&.latitude,
          longitude:    record.location&.longitude,
          ip:           Sentiero.configuration.capture_ip ? ip : nil
        )
      rescue MaxMind::GeoIP2::AddressNotFoundError
        nil
      end

      def self.require_maxmind!
        return if defined?(@maxmind_loaded) && @maxmind_loaded

        begin
          require "maxmind/geoip2"
        rescue LoadError
          raise Sentiero::Error, <<~MSG
            The maxmind-geoip2 gem is required for MaxMind geo resolution.
            Add `gem 'maxmind-geoip2'` to your Gemfile and run `bundle install`.
          MSG
        end
        @maxmind_loaded = true
      end
    end
  end
end
