# frozen_string_literal: true

require_relative "../events"
require_relative "../bounded"

module Sentiero
  module Analytics
    # Per-URL form interaction math. The single definition of what an "input"
    # and a "submit" are in rrweb terms. Two completion semantics for two callers:
    #   #completed_count — sessions with inputs where EVERY input segment was
    #     submitted (strict; one abandoned segment disqualifies).
    #   #submitted_count — sessions with ANY __form_submit event, regardless of
    #     input timing.
    class FormCollector
      include Events
      include Bounded

      # Recorder tag for a document-level form submit.
      SUBMIT_TAG = "__form_submit"

      # Output cap for the drop-off table.
      DROP_OFF_LIMIT = 50

      attr_reader :total_submits, :capped

      # max_fields: nil unbounded; an Integer caps the fields hash, flipping #capped.
      def initialize(max_fields: nil)
        @max_fields = max_fields
        @total_submits = 0
        @fields = {}            # [url, node_id] => field-stats hash
        @drop_off = Hash.new(0) # [url, node_id] => abandon count
        @started = {}           # session_id => true  (≥1 input event seen)
        @submitted = {}         # session_id => true  (≥1 submit event, any segment)
        @abandoned = {}         # session_id => true  (≥1 input segment not submitted)
        @capped = false
      end

      # Returns the count of input events found. labels: {node_id => label} from
      # the segment's DOM snapshot; {} omits them.
      def collect(session_id, url, segment, labels: {})
        @total_submits += segment.count { |e| submit?(e) }
        @submitted[session_id] = true if segment.any? { |e| submit?(e) }

        inputs = segment.select { |e| input?(e) }
        return 0 if inputs.empty?

        @started[session_id] = true
        record_fields(session_id, url, inputs, labels)

        first_input_at = inputs.first["timestamp"]
        unless segment_submitted?(segment, first_input_at)
          @abandoned[session_id] = true
          @drop_off[[url, node_id(inputs.last)]] += 1
        end

        inputs.size
      end

      def started_count
        @started.size
      end

      # Counts a submit on the target URL even when inputs landed on a prior segment.
      def submitted_count
        @submitted.size
      end

      # Sessions with inputs where NO input segment was abandoned; a submit on a
      # later page never masks an abandonment.
      def completed_count
        @started.count { |id, _| !@abandoned.key?(id) }
      end

      def summarize_fields(started, include_labels: false)
        @fields
          .sort_by { |(url, id), stats| [-stats[:sessions], url.to_s, id] }
          .map do |(url, id), stats|
            row = {}
            row[:field_id] = id
            row[:label] = stats[:label] if include_labels
            row[:url] = url
            row[:sessions] = stats[:sessions]
            row[:completion_rate] = started.zero? ? 0.0 : stats[:sessions].to_f / started
            row[:avg_time_to_fill_ms] = stats[:units].zero? ? 0.0 : stats[:total_fill_ms] / stats[:units]
            row[:total_refills] = stats[:total_refills]
            row
          end
      end

      def summarize_drop_off(include_labels: false)
        @drop_off
          .sort_by { |(url, id), count| [-count, url.to_s, id] }
          .first(DROP_OFF_LIMIT)
          .map do |(url, id), count|
            row = {}
            row[:field_id] = id
            row[:label] = @fields.key?([url, id]) ? @fields[[url, id]][:label] : nil if include_labels
            row[:url] = url
            row[:count] = count
            row
          end
      end

      private

      def input?(event)
        return false unless event["type"] == INCREMENTAL

        data = event["data"]
        data.is_a?(Hash) && data["source"] == SOURCE_INPUT && node_id(event)
      end

      def node_id(event)
        id = event.dig("data", "id")
        id.is_a?(Integer) ? id : nil
      end

      def submit?(event)
        event["type"] == CUSTOM && event.dig("data", "tag") == SUBMIT_TAG
      end

      # A segment counts as submitted only when a __form_submit lands at or
      # after the first input; an earlier submit belongs to a prior interaction
      # (counting it resurrects "navigating away counts as submitting").
      def segment_submitted?(segment, first_input_at)
        segment.any? do |event|
          next false unless submit?(event)

          ts = event["timestamp"]
          !first_input_at.is_a?(Numeric) || (ts.is_a?(Numeric) && ts >= first_input_at)
        end
      end

      # Keyed by [url, node_id]: rrweb node ids reset on every full-page load, so
      # the url scope keeps unrelated fields from conflating across pages.
      def record_fields(session_id, url, inputs, labels)
        inputs.group_by { |e| [url, node_id(e)] }.each do |key, field_inputs|
          stats = bounded_fetch(@fields, key, @max_fields) do
            {sessions: 0, units: 0, total_fill_ms: 0.0, total_refills: 0, last_session: nil, label: nil}
          end
          if stats.nil?
            @capped = true
            next
          end
          stats[:sessions] += 1 unless stats[:last_session] == session_id
          stats[:last_session] = session_id
          stats[:units] += 1
          timestamps = field_inputs.map { |e| e["timestamp"] }
          stats[:total_fill_ms] += (timestamps.max - timestamps.min).to_f
          stats[:total_refills] += field_inputs.size - 1
          stats[:label] ||= labels[node_id(field_inputs.first)]
        end
      end
    end
  end
end
