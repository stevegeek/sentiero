# frozen_string_literal: true

module Sentiero
  module Analytics
    class StatsAggregator
      # Pure presentation layer: turns a finished Accumulator into the
      # aggregate's public result hash. Needs the store only for the two
      # problem lookups (open_problems count and the top_problems list).
      class ResultBuilder
        include Events
        include Stats

        def initialize(store)
          @store = store
        end

        def build(acc, sessions_scanned, scan_cap, server_overlay_truncated)
          open_problems = store.list_problems(project: nil, limit: 10_000, status: "open")
          groups, series_bucket = bucket_groups(acc)
          series = groups.map { |label, dates| series_entry(acc, label, dates) }
          custom_event_tags = top_tags(acc.custom_tags.tags)

          {
            total_sessions: sessions_scanned,
            total_events: acc.total_events,
            sessions_scanned: sessions_scanned,
            avg_duration_ms: average(acc.durations),
            open_problems: open_problems.size,
            top_problems: top_problems(open_problems, acc.since),
            sessions_with_errors: acc.sessions_with_errors,
            event_type_breakdown: event_type_breakdown(acc.event_types),
            browser_distribution: sort_by_count(acc.browsers),
            device_distribution: sort_by_count(acc.devices),
            country_distribution: sort_by_count(acc.countries),
            city_distribution: sort_by_count(acc.cities),
            top_entry_pages: top_entry_pages(acc),
            top_referrers: top_list(acc.referrers, :referrer, StatsAggregator::TOP_LIST_LIMIT),
            session_duration_buckets: acc.duration_buckets,
            custom_event_tags: custom_event_tags,
            custom_event_tag_series: tag_series(acc, custom_event_tags, groups),
            browser_event_tags: acc.browser_tags,
            navigation: {
              internal: top_list(acc.nav_internal, :url, StatsAggregator::TOP_LIST_LIMIT),
              external: top_list(acc.nav_external, :url, StatsAggregator::TOP_LIST_LIMIT),
              top_texts: top_list(acc.nav_texts, :text, StatsAggregator::TOP_LIST_LIMIT)
            },
            metadata_distributions: metadata_distributions(acc),
            events_per_day_series: series,
            series_bucket: series_bucket,
            # True when a cap was hit: server_error_count values are then a lower bound.
            server_overlay_truncated: server_overlay_truncated,
            # Effective bounds (unbounded "until" resolves to now) for period-over-period.
            window_since: acc.since,
            window_until: acc.until_time || Time.now.to_f,
            was_truncated: sessions_scanned >= scan_cap
          }
        end

        private

        attr_reader :store

        def top_problems(open_problems, since)
          open_problems
            .sort_by { |problem| -problem[:count].to_i }
            .first(StatsAggregator::TOP_PROBLEMS_LIMIT)
            .map do |problem|
              {
                id: problem[:id],
                exception_class: problem[:exception_class],
                message: problem[:message],
                count: problem[:count],
                first_seen: problem[:first_seen],
                new: !!(problem[:first_seen] && problem[:first_seen] >= since)
              }
            end
        end

        def event_type_breakdown(types)
          {
            incremental: types[INCREMENTAL],
            meta: types[META],
            custom: types[CUSTOM]
          }
        end

        def average(values)
          return nil if values.empty?
          values.sum / values.size.to_f
        end

        def sort_by_count(counts)
          top_counts(counts, limit: counts.size).to_h
        end

        def top_list(counts, key, limit)
          top_counts(counts, limit: limit).map { |value, count| {key => value, :count => count} }
        end

        def top_tags(counts)
          top_counts(counts, limit: StatsAggregator::TOP_TAGS_LIMIT).to_h
        end

        def metadata_distributions(acc)
          acc.metadata_keys
            .sort_by { |_key, count| -count }
            .first(StatsAggregator::TOP_LIST_LIMIT)
            .map do |key, count|
              {key: key, count: count, values: top_list(acc.metadata_values[key] || {}, :value, 5)}
            end
        end

        def top_entry_pages(acc)
          top_list(acc.entry_pages, :url, StatsAggregator::TOP_LIST_LIMIT).map do |row|
            row.merge(error_count: acc.entry_page_errors[row[:url]])
          end
        end

        # One bucket per UTC day, or per ISO week past WEEK_BUCKET_THRESHOLD_DAYS.
        # Main and per-tag series share these groups so they align.
        def bucket_groups(acc)
          start_date = Time.at(acc.since).utc.to_date
          end_date = (acc.until_time ? Time.at(acc.until_time) : Time.now).utc.to_date
          end_date = start_date if end_date < start_date
          days = (start_date..end_date).to_a

          if days.size > StatsAggregator::WEEK_BUCKET_THRESHOLD_DAYS
            [days.group_by { |date| date.strftime("%G-W%V") }.to_a, "week"]
          else
            [days.map { |date| [date.to_s, [date]] }, "day"]
          end
        end

        def tag_series(acc, custom_event_tags, groups)
          custom_event_tags.keys.filter_map do |tag|
            per_day = acc.per_day_tags[tag]
            next unless per_day

            [tag, groups.map { |label, dates| {date: label, count: dates.sum { |date| per_day[date.to_s] }} }]
          end.to_h
        end

        def series_entry(acc, label, dates)
          {
            date: label,
            event_count: dates.sum { |date| acc.per_day_events[date.to_s] },
            session_count: dates.sum { |date| acc.per_day_sessions[date.to_s] },
            error_count: dates.sum { |date| acc.per_day_errors[date.to_s] },
            server_error_count: dates.sum { |date| acc.per_day_server_errors[date.to_s] }
          }
        end
      end
    end
  end
end
