# frozen_string_literal: true

require "uri"

require_relative "analyzer"
require_relative "funnel_analyzer"

module Sentiero
  module Analytics
    # Conversion rate by acquisition dimension (entry page, referrer host, UTM)
    # for one custom-event tag. A session counts as converting at most once,
    # regardless of how many times/windows the tag fired.
    class ConversionAnalyzer < Analyzer
      TOP_ROWS = 15

      # Below this many sessions a rate is too thin; rows flagged low_volume.
      MIN_SESSIONS_FOR_RATE = 5

      # A new key past the cap is dropped and sets was_truncated.
      MAX_DIMENSION_KEYS = 200

      DIRECT = "(direct / none)"

      # Matched case-insensitively.
      UTM_PARAMS = %w[utm_source utm_medium utm_campaign].freeze

      # No tag selected → empty facets, but tag vocabulary is still collected.
      def analyze(tag = nil, limit: nil, since: nil, until_time: nil)
        selected = FunnelAnalyzer.usable_steps([tag].compact).first

        tags = {}
        sessions = {}
        @truncated = false

        _scanned, hit_cap = scan_sessions(limit: limit, since: since, until_time: until_time) do |summary, window_id, events|
          session_id = summary[:session_id]
          state = sessions[session_id] ||= new_state(summary, window_id)

          update_entry_candidate(state, events)
          collect_vocabulary(tags, events)
          record_conversion(state, selected, window_id, events) if selected
        end

        facets = selected ? build_facets(sessions) : empty_facets

        {
          tags: tags.keys.sort,
          selected_tag: selected,
          entry_pages: facets[:entry_pages],
          referrers: facets[:referrers],
          utm: facets[:utm],
          was_truncated: @truncated || hit_cap
        }
      end

      private

      # entry_url precedence: an explicit entry_url is authoritative (anchor
      # -Infinity so no later Meta can displace it), else the first Meta href wins.
      def new_state(summary, first_window)
        metadata = summary[:metadata] || {}
        entry_url = metadata["entry_url"]
        {
          session_id: summary[:session_id],
          entry_url: entry_url,
          entry_anchor: entry_url ? -Float::INFINITY : nil,
          referrer: metadata["entry_referrer"] || metadata["referrer"],
          converted: false,
          convert_window: nil,
          convert_offset: nil,
          convert_anchor: nil,
          first_window: first_window
        }
      end

      def collect_vocabulary(tags, events)
        events.each do |event|
          next unless event.is_a?(Hash) && event["type"] == CUSTOM
          data = event["data"]
          next unless data.is_a?(Hash)
          tag = data["tag"]
          next if FunnelAnalyzer.internal_tag?(tag)

          next if tags.key?(tag)
          if tags.size >= FunnelAnalyzer::MAX_TAGS
            @truncated = true
            next
          end
          tags[tag] = true
        end
      end

      # Keeps the earliest conversion across windows so example coordinates are
      # deterministic (earlier window start, or same start with earlier offset).
      def record_conversion(state, tag, window_id, events)
        anchor = events.first&.fetch("timestamp", nil)
        match = events.find do |event|
          event.is_a?(Hash) && event["type"] == CUSTOM &&
            event["data"].is_a?(Hash) && event["data"]["tag"] == tag &&
            event["timestamp"].is_a?(Numeric)
        end
        return unless match

        offset = offset_ms(anchor, match["timestamp"])
        return if state[:converted] && !earlier_match?(anchor, offset, state)

        state[:converted] = true
        state[:convert_window] = window_id
        state[:convert_offset] = offset
        state[:convert_anchor] = anchor
      end

      def earlier_match?(anchor, offset, state)
        cur_anchor = state[:convert_anchor]
        if anchor.is_a?(Numeric) && cur_anchor.is_a?(Numeric)
          return true if anchor < cur_anchor
          return false if anchor > cur_anchor
          return offset < state[:convert_offset]
        end
        false
      end

      def empty_facets
        {entry_pages: [], referrers: [], utm: {source: [], medium: [], campaign: []}}
      end

      # Runs after the scan, so every window of every session has been seen.
      def build_facets(sessions)
        entry_pages = new_facet
        referrers = new_facet
        utm = {source: new_facet, medium: new_facet, campaign: new_facet}

        sessions.each_value do |state|
          entry_url = state[:entry_url]
          entry_key = normalize_entry(entry_url)
          # No resolvable entry page => no acquisition data; contribute to no facet.
          next unless entry_key

          fold(entry_pages, entry_key, state)
          fold(referrers, referrer_key(state[:referrer], entry_url), state)
          fold_utm(utm, entry_url, state)
        end

        {
          entry_pages: rows_for(entry_pages),
          referrers: rows_for(referrers),
          utm: {
            source: rows_for(utm[:source]),
            medium: rows_for(utm[:medium]),
            campaign: rows_for(utm[:campaign])
          }
        }
      end

      def new_facet
        {sessions: Hash.new(0), conversions: Hash.new(0), converting: {}, non_converting: {}}
      end

      def fold(facet, key, state)
        return if key.nil?

        if !facet[:sessions].key?(key) && facet[:sessions].size >= MAX_DIMENSION_KEYS
          @truncated = true
          return
        end

        facet[:sessions][key] += 1
        if state[:converted]
          facet[:conversions][key] += 1
          facet[:converting][key] ||= {
            session_id: state[:session_id],
            window_id: state[:convert_window],
            offset_ms: state[:convert_offset]
          }
        else
          facet[:non_converting][key] ||= {
            session_id: state[:session_id],
            window_id: state[:first_window],
            offset_ms: 0
          }
        end
      end

      def fold_utm(utm, entry_url, state)
        params = utm_params(entry_url)
        fold(utm[:source], params["utm_source"], state)
        fold(utm[:medium], params["utm_medium"], state)
        fold(utm[:campaign], params["utm_campaign"], state)
      end

      def normalize_entry(url)
        return nil unless url.is_a?(String) && !url.empty?

        uri = URI.parse(url)
        return nil unless uri.scheme && uri.host

        port = (uri.port && uri.port != uri.default_port) ? ":#{uri.port}" : ""
        "#{uri.scheme}://#{uri.host}#{port}#{uri.path}"
      rescue URI::InvalidURIError
        nil
      end

      # Same-origin referrers are from within the site, not acquisition, so dropped.
      def referrer_key(referrer, entry_url)
        return nil if same_origin?(referrer, entry_url)
        return DIRECT unless referrer.is_a?(String) && !referrer.empty?

        host = URI.parse(referrer).host
        (host && !host.empty?) ? host : DIRECT
      rescue URI::InvalidURIError
        DIRECT
      end

      def utm_params(url)
        out = {}
        return out unless url.is_a?(String) && url.include?("?")

        query = url.split("?", 2)[1].split("#", 2)[0]
        URI.decode_www_form(query).each do |key, value|
          name = key.to_s.downcase
          next unless UTM_PARAMS.include?(name)
          next if out.key?(name)
          stripped = value.to_s.strip
          out[name] = stripped unless stripped.empty?
        end
        out
      rescue ArgumentError
        out
      end

      def rows_for(facet)
        top_counts(facet[:sessions], limit: TOP_ROWS).map do |key, sessions|
          conversions = facet[:conversions][key]
          {
            key: key,
            sessions: sessions,
            conversions: conversions,
            conversion_rate: sessions.zero? ? nil : (conversions.to_f / sessions * 100).round(1),
            low_volume: sessions < MIN_SESSIONS_FOR_RATE,
            converting_example: facet[:converting][key],
            non_converting_example: facet[:non_converting][key]
          }
        end
      end
    end
  end
end
