# frozen_string_literal: true

require_relative "analyzer"
require_relative "../user_agent"

module Sentiero
  module Analytics
    # Filters sessions on read by browser/device/URL/metadata/has-errors/duration
    # (AND-combined), scanning up to the store's limits.analytics_max_scan_sessions.
    class Segmenter < Analyzer
      def initialize(
        store = Sentiero.store,
        browser: nil,
        device: nil,
        url_pattern: nil,
        metadata_key: nil,
        metadata_value: nil,
        metadata_match: "exact",
        has_errors: false,
        min_duration_ms: nil,
        max_duration_ms: nil,
        country: nil,
        since: nil,
        until_time: nil
      )
        super(store)
        @browser = presence(browser)
        @device = presence(device)
        @url_pattern = presence(url_pattern)
        @metadata_key = presence(metadata_key)
        @metadata_value = presence(metadata_value)
        @metadata_match = (metadata_match == "contains") ? "contains" : "exact"
        @has_errors = has_errors
        @min_duration_ms = min_duration_ms
        @max_duration_ms = max_duration_ms
        # Country codes compare case-insensitively (Cloudflare sends uppercase
        # ISO-2; a custom proc may not).
        @country = presence(country)&.upcase
        @since = since
        @until_time = until_time
      end

      def matching(limit: 20, offset: 0)
        scan_cap = store.limits.analytics_max_scan_sessions

        scanned = store.list_sessions(limit: scan_cap, offset: 0, since: @since, until_time: @until_time)
        # Collected pre-filter (and in the same scan, so the dropdown costs no
        # extra store pass): the country dropdown must list every scanned
        # country, not just the currently selected one.
        countries = scanned.filter_map { |s| s[:metadata]&.[]("geo_country") }.uniq.sort
        matches = scanned.select { |summary| match?(summary) }

        page = matches.slice(offset, limit + 1) || []
        has_next = page.size > limit

        {
          sessions: page.first(limit),
          has_next: has_next,
          was_truncated: scanned.size >= scan_cap,
          countries: countries
        }
      end

      private

      def presence(value)
        return nil unless value.is_a?(String)
        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def match?(summary)
        metadata = summary[:metadata] || {}

        browser_match?(metadata) &&
          device_match?(metadata) &&
          country_match?(metadata) &&
          url_match?(metadata) &&
          metadata_match?(metadata) &&
          has_errors_match?(metadata) &&
          duration_match?(summary)
      end

      def browser_match?(metadata)
        return true unless @browser

        UserAgent.browser(metadata["userAgent"]) == @browser
      end

      def device_match?(metadata)
        return true unless @device

        UserAgent.device(metadata["userAgent"]) == @device
      end

      def country_match?(metadata)
        return true unless @country

        metadata["geo_country"].to_s.upcase == @country
      end

      def url_match?(metadata)
        return true unless @url_pattern

        url = metadata["url"]
        return false unless url.is_a?(String)

        glob?(@url_pattern) ? glob_match?(url, @url_pattern) : url.downcase.include?(@url_pattern.downcase)
      end

      def glob?(pattern)
        pattern.include?("*") || pattern.include?("?")
      end

      def glob_match?(url, pattern)
        File.fnmatch(pattern, url, File::FNM_CASEFOLD)
      end

      def metadata_match?(metadata)
        return true unless @metadata_key
        return false unless metadata.key?(@metadata_key)
        return true unless @metadata_value

        value = metadata[@metadata_key].to_s
        if @metadata_match == "contains"
          value.downcase.include?(@metadata_value.downcase)
        else
          value == @metadata_value
        end
      end

      def has_errors_match?(metadata)
        return true unless @has_errors

        metadata["has_errors"] == true
      end

      def duration_match?(summary)
        return true unless @min_duration_ms || @max_duration_ms

        duration = duration_ms(summary)
        return false if duration.nil?
        return false if @min_duration_ms && duration < @min_duration_ms
        return false if @max_duration_ms && duration > @max_duration_ms
        true
      end
    end
  end
end
