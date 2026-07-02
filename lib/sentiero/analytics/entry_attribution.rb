# frozen_string_literal: true

require "uri"

module Sentiero
  module Analytics
    # Shared "earliest entry page" attribution, mixed into Analyzer so every
    # analyzer gets it (StatsAggregator/ConversionAnalyzer use it directly;
    # EngagementAnalyzer reuses only #earlier?, see its own track_entry_url —
    # it scans every Meta in a window for the globally-earliest one instead of
    # deferring to the window's first Meta, so it isn't update_entry_candidate).
    #
    # entry_url precedence: an explicit entry_url from session metadata is
    # authoritative (callers anchor it at -Infinity so no Meta can displace
    # it); otherwise the first Meta href of the earliest-starting window wins.
    module EntryAttribution
      # a "earlier than" b. nil_anchor_is_earlier: true lets a later,
      # well-timed candidate displace one whose anchor came back nil (an
      # accepted Meta whose own event lacked a numeric timestamp) —
      # EngagementAnalyzer's track_entry_url needs this because it can accept
      # a nil-anchor candidate on the first match it sees. StatsAggregator and
      # ConversionAnalyzer never reach that state: their nil-anchor candidate
      # is only ever the FIRST one (accepted unconditionally via the
      # `entry_url.nil?` guard before earlier? is consulted), so the default
      # (false) is the correct, stricter behavior for them.
      def earlier?(a, b, nil_anchor_is_earlier: false)
        return false unless a.is_a?(Numeric)
        return true if b.nil? && nil_anchor_is_earlier

        b.is_a?(Numeric) && a < b
      end

      def first_meta_href(events)
        events.each do |event|
          href = meta_href(event)
          return href if href
        end
        nil
      end

      # Deferred candidate for one session, updated once per window: the
      # window's first Meta href, anchored by the WINDOW's first event
      # timestamp (not the Meta's own timestamp) so windows compare by when
      # they started, not by their first navigation's exact instant.
      def update_entry_candidate(state, events)
        href = first_meta_href(events)
        return unless href

        anchor = events.first&.fetch("timestamp", nil)
        return unless state[:entry_url].nil? || earlier?(anchor, state[:entry_anchor])

        state[:entry_url] = href
        state[:entry_anchor] = anchor
      end

      # Self-referral: same scheme://host:port. Unparseable or host-less values
      # return false (kept — not provably internal).
      def same_origin?(referrer, entry_url)
        return false unless referrer.is_a?(String) && entry_url.is_a?(String)

        ref = URI.parse(referrer)
        entry = URI.parse(entry_url)
        return false unless ref.host && entry.host

        ref.scheme == entry.scheme && ref.host == entry.host && ref.port == entry.port
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
