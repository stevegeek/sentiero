# frozen_string_literal: true

module Sentiero
  module GeoResolvers
    class CloudflareResolver
      include GeoResolver

      # Cloudflare header -> Rack env key mapping
      # Rack uppercases headers, replaces dashes with underscores, and prepends HTTP_
      HEADER_MAP = {
        country_code: "HTTP_CF_IPCOUNTRY",
        city:         "HTTP_CF_IPCITY",
        region:       "HTTP_CF_REGION",
        region_code:  "HTTP_CF_REGION_CODE",
        postal_code:  "HTTP_CF_POSTAL_CODE",
        timezone:     "HTTP_CF_TIMEZONE",
        latitude:     "HTTP_CF_IPLATITUDE",
        longitude:    "HTTP_CF_IPLONGITUDE"
      }.freeze

      IP_HEADER = "HTTP_CF_CONNECTING_IP"

      def resolve(request)
        env = request.env

        # No Cloudflare headers present — not behind Cloudflare or headers not enabled
        return nil unless env[HEADER_MAP[:country_code]]

        attrs = {}

        HEADER_MAP.each do |field, header|
          attrs[field] = env[header]
        end

        # Cast coordinates to Float when present
        attrs[:latitude]  = attrs[:latitude].to_f  if attrs[:latitude]
        attrs[:longitude] = attrs[:longitude].to_f if attrs[:longitude]

        # Capture IP unless disabled for privacy
        attrs[:ip] = env[IP_HEADER] if Sentiero.configuration.capture_ip

        GeoLocation.new(**attrs)
      end
    end
  end
end
