# frozen_string_literal: true

module Sentiero
  class Configuration
    attr_accessor :geo_resolver, :maxmind_database_path, :capture_ip

    def initialize
      @geo_resolver = :cloudflare
      @maxmind_database_path = nil
      @capture_ip = true
    end

    def build_resolver
      case geo_resolver
      when :cloudflare
        GeoResolvers::CloudflareResolver.new
      when :maxmind
        require "sentiero/geo_resolvers/maxmind_resolver"
        GeoResolvers::MaxmindResolver.new(maxmind_database_path)
      when :none, nil
        nil
      else
        # Duck-typed custom resolver — must respond to #resolve(request)
        geo_resolver
      end
    end
  end
end
