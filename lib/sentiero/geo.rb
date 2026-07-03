# frozen_string_literal: true

module Sentiero
  # Deliberately coarse — country/city/region/timezone, no coordinates, no IP:
  # resolution happens in-request and only the result is stored, so
  # config.anonymize_ip is unaffected.
  module Geo
    MAX_VALUE_LENGTH = 256
    PROC_WARNING_LOCK = Mutex.new
    @proc_warning_emitted = false

    # CF-IPCountry ships with Cloudflare IP geolocation; the other headers need
    # the "Add visitor location headers" managed transform, so country-only is the common case.
    CLOUDFLARE_HEADERS = {
      "geo_country" => "HTTP_CF_IPCOUNTRY",
      "geo_city" => "HTTP_CF_IPCITY",
      "geo_region" => "HTTP_CF_REGION",
      "geo_timezone" => "HTTP_CF_TIMEZONE"
    }.freeze

    # Cloudflare placeholder codes: XX = unknown, T1 = Tor exit.
    CLOUDFLARE_UNKNOWN = %w[XX T1].freeze

    PROC_KEY_MAP = {
      "country" => "geo_country",
      "city" => "geo_city",
      "region" => "geo_region",
      "timezone" => "geo_timezone"
    }.freeze

    module_function

    def resolve(env, source)
      case source
      when nil then {}
      when :cloudflare then from_cloudflare(env)
      else from_proc(env, source)
      end
    end

    def from_cloudflare(env)
      geo = CLOUDFLARE_HEADERS.each_with_object({}) do |(key, header), acc|
        value = clean(env[header])
        acc[key] = value if value
      end
      geo.delete("geo_country") if CLOUDFLARE_UNKNOWN.include?(geo["geo_country"])
      geo
    end

    # A broken geo hook must never break ingest: rescue everything, warn once
    # per process, resolve empty.
    def from_proc(env, source)
      raw = source.call(env)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), acc|
        mapped = PROC_KEY_MAP[key.to_s]
        value = clean(value)
        acc[mapped] = value if mapped && value
      end
    rescue => e
      PROC_WARNING_LOCK.synchronize do
        return {} if @proc_warning_emitted
        @proc_warning_emitted = true
      end

      warn "[Sentiero] geo_source raised #{e.class}: #{e.message}; skipping geo capture"
      {}
    end

    def reset_proc_warning!
      @proc_warning_emitted = false
    end

    def clean(value)
      return nil unless value.is_a?(String)

      stripped = value.strip
      return nil if stripped.empty?

      stripped[0, MAX_VALUE_LENGTH]
    end
  end
end
