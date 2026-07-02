# frozen_string_literal: true

require "securerandom"
require_relative "models/session"
require_relative "models/event"
require_relative "models/problem"
require_relative "models/occurrence"
require_relative "models/server_event"

module Sentiero
  module Rails
    class Store < Sentiero::Store
      def initialize(limits: nil)
        @limits = limits
      end

      def save_events(ref, events)
        return if events.nil? || events.empty?
        session_id, window_id = ref.session_id, ref.window_id

        now = Time.now

        Session.transaction do
          session = find_or_create_session!(session_id, now)
          session.update_column(:updated_at, now) unless session.previously_new_record?

          rows = events.map { |event|
            {
              session_id: session_id,
              window_id: window_id,
              timestamp: event["timestamp"]&.to_f,
              data: event,
              created_at: now
            }
          }
          Event.insert_all(rows)

          enforce_max_events_per_session(session_id)
          enforce_max_sessions(session_id)
        end

        nil
      end

      # Batched scan: one events query for the whole session page instead of the
      # base's get_session + get_events per window.
      def each_session_events(limit: nil, since: nil, until_time: nil)
        return enum_for(:each_session_events, limit: limit, since: since, until_time: until_time) unless block_given?

        cap = limit || limits.analytics_max_scan_sessions
        summaries = list_sessions(limit: cap, since: since, until_time: until_time)
        return if summaries.empty?

        events = events_by_session_window(summaries.map { |summary| summary[:session_id] })
        summaries.each do |summary|
          (events[summary[:session_id]] || {}).each do |window_id, window_events|
            yield summary, window_id, window_events
          end
        end
      end

      def list_sessions(limit:, offset: 0, since: nil, until_time: nil, sort_by: nil, search: nil)
        scope = filtered_session_scope(since:, until_time:, search:)
        scope = ordered_session_scope(scope, sort_by)

        sessions = scope.offset(offset).limit(limit).to_a
        return [] if sessions.empty?

        sids = sessions.map(&:session_id)
        window_ids_by_session = window_ids_for(sids)
        counts_by_session = event_counts_for(sids)
        timestamp_ranges = timestamp_ranges_for(sids)

        sessions.map { |session|
          session_summary(session, window_ids_by_session, counts_by_session, timestamp_ranges)
        }
      end

      def get_session(session_id)
        validate_id!(session_id)
        session = Session.find_by(session_id: session_id)
        return nil unless session

        window_stats = Event.where(session_id: session_id)
          .group(:window_id)
          .pluck(:window_id, Arel.sql("COUNT(*)"), Arel.sql("MIN(timestamp)"), Arel.sql("MAX(timestamp)"))

        window_data = window_stats.map { |wid, count, first_ts, last_ts|
          entry = {window_id: wid, event_count: count}
          entry[:first_event_at] = first_ts.to_f if first_ts
          entry[:last_event_at] = last_ts.to_f if last_ts
          entry
        }

        timestamps = Event.where(session_id: session_id)
          .pick(Arel.sql("MIN(timestamp)"), Arel.sql("MAX(timestamp)"))

        result = {
          session_id: session.session_id,
          windows: window_data,
          created_at: session.created_at.to_f,
          updated_at: session.updated_at.to_f,
          first_event_at: timestamps&.first&.to_f,
          last_event_at: timestamps&.last&.to_f
        }
        if metadata_column? && session.metadata.present?
          result[:metadata] = session.metadata
        end
        result
      end

      def get_events(ref, after: nil, limit: nil)
        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id
        scope = Event.where(session_id: session_id, window_id: window_id)
          .order(timestamp: :asc)

        scope = scope.where("timestamp > ?", after.to_f) if after
        scope = scope.limit(limit) if limit

        scope.map(&:data)
      end

      def save_metadata(session_id, metadata)
        return unless metadata.is_a?(Hash) && !metadata.empty?
        return unless metadata_column?
        validate_metadata!(metadata)

        session = Session.find_by(session_id: session_id)
        return unless session

        # Locked reload-merge-save, mirroring save_occurrence's Problem.lock:
        # an unlocked read-modify-write here drops keys from a concurrent
        # merge (e.g. this same method called for "has_errors" from
        # save_occurrence racing a client-supplied metadata update).
        session.with_lock do
          existing = session.metadata || {}
          session.update_column(:metadata, existing.merge(metadata.transform_keys(&:to_s)))
        end
        nil
      end

      def delete_session(session_id)
        validate_id!(session_id)
        Session.transaction do
          destroy_session_data(session_id)
        end
        nil
      end

      def delete_window(ref)
        validate_window_ref!(ref)
        session_id, window_id = ref.session_id, ref.window_id
        Session.transaction do
          Event.where(session_id: session_id, window_id: window_id).delete_all

          remaining = Event.where(session_id: session_id).exists?
          unless remaining
            Session.where(session_id: session_id).delete_all
          end
        end
        nil
      end

      # Subquery-based DELETEs avoid loading stale ids into Ruby and large IN (...) lists.
      def purge_older_than(seconds)
        cutoff = Time.at(Time.now.to_f - seconds)
        cutoff_f = cutoff.to_f
        session_count = nil

        Session.transaction do
          stale = Session.where("updated_at < ?", cutoff)
          Event.where(session_id: stale.select(:session_id)).delete_all
          session_count = stale.delete_all

          ServerEvent.where("timestamp < ?", cutoff_f).delete_all
          Occurrence.where("timestamp < ?", cutoff_f).delete_all
          stale_fps = Problem.where("last_seen < ?", cutoff_f).pluck(:fingerprint)
          unless stale_fps.empty?
            Occurrence.where(fingerprint: stale_fps).delete_all
            Problem.where(fingerprint: stale_fps).delete_all
          end
        end

        session_count
      end

      def save_occurrence(occurrence)
        validate_occurrence!(occurrence)
        fp = occurrence["fingerprint"]
        ts = occurrence["timestamp"].to_f
        occ_id = SecureRandom.uuid
        stored = occurrence.merge("id" => occ_id)

        # On a concurrent insert of a new fingerprint one writer's save! raises
        # (RecordInvalid from the uniqueness validator, or RecordNotUnique from the
        # DB index); retry so the loser re-runs and takes the "existing" branch.
        attempts = 0
        begin
          Problem.transaction do
            # SELECT ... FOR UPDATE so the count+1 / last_seen read-modify-write is
            # serialized; an unlocked find lost concurrent updates under READ COMMITTED.
            problem = Problem.lock.find_by(fingerprint: fp)
            if problem
              reopening = problem.status == "resolved"
              problem.count += 1
              problem.first_seen = [problem.first_seen, ts].min
              problem.last_seen = [problem.last_seen, ts].max
              problem.message = occurrence["message"]
              if reopening
                problem.status = "open"
                problem.resolved_at = nil
              end
            else
              problem = Problem.new(fingerprint: fp)
              problem.project = occurrence["project"]
              problem.exception_class = occurrence["exception_class"]
              problem.title = build_problem_title(occurrence)
              problem.message = occurrence["message"]
              problem.count = 1
              problem.status = "open"
              problem.first_seen = ts
              problem.last_seen = ts
              problem.resolved_at = nil
            end
            problem.save!

            Occurrence.create!(
              occurrence_id: occ_id,
              fingerprint: fp,
              session_id: occurrence["session_id"],
              timestamp: ts,
              data: stored
            )

            enforce_max_problems
          end
        rescue ::ActiveRecord::RecordNotUnique
          attempts += 1
          retry if attempts < 2
          raise
        rescue ::ActiveRecord::RecordInvalid => e
          raise unless e.record.errors[:fingerprint].any?
          attempts += 1
          retry if attempts < 2
          raise
        end

        save_metadata(occurrence["session_id"], {"has_errors" => true}) if occurrence["session_id"]
        fp
      end

      def list_problems(project:, limit:, offset: 0, status: nil, sort_by: nil, search: nil, since: nil, until_time: nil)
        scope = Problem.all
        scope = scope.where(project: project) unless project.nil?
        scope = scope.where(status: status) if status
        scope = scope.where("last_seen >= ?", since.to_f) if since
        scope = scope.where("last_seen <= ?", until_time.to_f) if until_time
        if search && !search.empty?
          pattern = "%#{search}%"
          scope = scope.where("title LIKE ? OR exception_class LIKE ?", pattern, pattern)
        end
        scope = case sort_by
        when "first_seen" then scope.order(first_seen: :desc)
        when "count" then scope.order(count: :desc)
        else scope.order(last_seen: :desc)
        end
        scope.offset(offset).limit(limit).map { |p| problem_to_hash(p) }
      end

      def get_problem(problem_id)
        validate_id!(problem_id)
        problem = Problem.find_by(fingerprint: problem_id)
        problem ? problem_to_hash(problem) : nil
      end

      def get_occurrences(problem_id, after: nil, limit: nil)
        validate_id!(problem_id)
        scope = Occurrence.where(fingerprint: problem_id).order(timestamp: :asc)
        scope = scope.where("timestamp > ?", after.to_f) if after
        scope = scope.limit(limit) if limit
        scope.map(&:data)
      end

      # COUNT in SQL instead of materializing every row.
      def count_occurrences(problem_id, after: nil)
        validate_id!(problem_id)
        scope = Occurrence.where(fingerprint: problem_id)
        scope = scope.where("timestamp > ?", after.to_f) if after
        scope.count
      end

      def update_problem_status(problem_id, status)
        validate_id!(problem_id)
        validate_status!(status)
        resolved_at = (status == "resolved") ? Time.now.to_f : nil
        Problem.where(fingerprint: problem_id).update_all(status: status, resolved_at: resolved_at)
        nil
      end

      def save_server_event(event)
        validate_server_event!(event)
        ev_id = SecureRandom.uuid
        stored = event.merge("id" => ev_id)
        ServerEvent.transaction do
          ServerEvent.create!(
            event_id: ev_id,
            project: event["project"],
            name: event["name"],
            level: event["level"],
            session_id: event["session_id"],
            timestamp: event["timestamp"].to_f,
            data: stored
          )
          enforce_max_server_events
        end
        nil
      end

      def get_server_event(event_id)
        validate_id!(event_id)
        ServerEvent.find_by(event_id: event_id)&.data
      end

      def list_server_events(project:, limit:, name: nil, level: nil, session_id: nil, after: nil)
        scope = ServerEvent.all
        scope = scope.where(project: project) unless project.nil?
        scope = scope.order(timestamp: :asc)
        scope = scope.where(name: name) if name
        scope = scope.where(level: level) if level
        scope = scope.where(session_id: session_id) if session_id
        scope = scope.where("timestamp > ?", after.to_f) if after
        scope.limit(limit).map(&:data)
      end

      def occurrences_for_session(session_id, limit: nil)
        validate_id!(session_id)
        scope = Occurrence.where(session_id: session_id).order(timestamp: :asc)
        scope = scope.limit(limit) if limit
        scope.map(&:data)
      end

      def server_events_for_session(session_id, limit: nil)
        validate_id!(session_id)
        scope = ServerEvent.where(session_id: session_id).order(timestamp: :asc)
        scope = scope.limit(limit) if limit
        scope.map(&:data)
      end

      def session_ids_for_problem(problem_id, limit: nil)
        validate_id!(problem_id)
        scope = Occurrence.where(fingerprint: problem_id)
          .where.not(session_id: nil)
          .group(:session_id)
          .order(Arel.sql("MAX(timestamp) DESC"))
          .pluck(:session_id)
        limit ? scope.first(limit) : scope
      end

      private

      def metadata_column?
        Session.column_names.include?("metadata")
      end

      def filtered_session_scope(since:, until_time:, search:)
        scope = Session.all
        scope = scope.where("updated_at >= ?", Time.at(since.to_f)) if since
        scope = scope.where("updated_at <= ?", Time.at(until_time.to_f)) if until_time

        if search && !search.empty?
          pattern = "%#{search}%"
          scope = if metadata_column?
            scope.where("session_id LIKE ? OR CAST(metadata AS TEXT) LIKE ?", pattern, pattern)
          else
            scope.where("session_id LIKE ?", pattern)
          end
        end

        scope
      end

      def ordered_session_scope(scope, sort_by)
        if sort_by == "event_count"
          scope
            .joins("LEFT JOIN #{Event.table_name} ON #{Event.table_name}.session_id = #{Session.table_name}.session_id")
            .group("#{Session.table_name}.id")
            .order(Arel.sql("COUNT(#{Event.table_name}.id) DESC"))
        else
          sort_column = case sort_by
          when "created_at" then :created_at
          else :updated_at
          end
          scope.order(sort_column => :desc)
        end
      end

      def window_ids_for(session_ids)
        Event.where(session_id: session_ids)
          .distinct.pluck(:session_id, :window_id)
          .group_by(&:first)
          .transform_values { |pairs| pairs.map(&:last) }
      end

      def events_by_session_window(session_ids)
        grouped = Hash.new { |h, sid| h[sid] = {} }
        Event.where(session_id: session_ids).order(:timestamp).each do |event|
          (grouped[event.session_id][event.window_id] ||= []) << event.data
        end
        grouped
      end

      def event_counts_for(session_ids)
        Event.where(session_id: session_ids)
          .group(:session_id).count
      end

      def timestamp_ranges_for(session_ids)
        Event.where(session_id: session_ids)
          .group(:session_id)
          .pluck(:session_id, Arel.sql("MIN(timestamp)"), Arel.sql("MAX(timestamp)"))
          .to_h { |sid, min_ts, max_ts| [sid, {first: min_ts&.to_f, last: max_ts&.to_f}] }
      end

      def session_summary(session, window_ids_by_session, counts_by_session, timestamp_ranges)
        range = timestamp_ranges[session.session_id]
        summary_hash(
          session_id: session.session_id,
          window_ids: window_ids_by_session[session.session_id] || [],
          event_count: counts_by_session[session.session_id] || 0,
          created_at: session.created_at.to_f,
          updated_at: session.updated_at.to_f,
          first_event_at: range&.dig(:first),
          last_event_at: range&.dig(:last),
          metadata: metadata_column? ? session.metadata : nil
        )
      end

      def find_or_create_session!(session_id, now)
        Session.find_or_create_by!(session_id: session_id) do |s|
          s.created_at = now
          s.updated_at = now
        end
      rescue ::ActiveRecord::RecordNotUnique
        Session.find_by!(session_id: session_id)
      end

      def enforce_max_events_per_session(session_id)
        max_events = limits.max_events_per_session
        return unless max_events

        total = Event.where(session_id: session_id).count
        return unless total > max_events

        excess = total - max_events
        oldest_ids = Event.where(session_id: session_id)
          .order(timestamp: :asc)
          .limit(excess)
          .pluck(:id)
        Event.where(id: oldest_ids).delete_all
      end

      def enforce_max_sessions(protected_session_id)
        max_sessions = limits.max_sessions
        return unless max_sessions

        total = Session.count
        return unless total > max_sessions

        to_evict = total - max_sessions
        oldest = Session.where.not(session_id: protected_session_id)
          .order(updated_at: :asc)
          .limit(to_evict)
          .pluck(:session_id)

        return if oldest.empty?

        Event.where(session_id: oldest).delete_all
        Session.where(session_id: oldest).delete_all
      end

      def destroy_session_data(session_id)
        Event.where(session_id: session_id).delete_all
        Session.where(session_id: session_id).delete_all
        # GDPR erasure of session-scoped rows. The Problem aggregate is retained,
        # though its title/message may still hold PII — a known erasure residue.
        Occurrence.where(session_id: session_id).delete_all
        ServerEvent.where(session_id: session_id).delete_all
      end

      def problem_to_hash(problem)
        {
          id: problem.fingerprint,
          project: problem.project,
          exception_class: problem.exception_class,
          title: problem.title,
          message: problem.message,
          count: problem.count,
          status: problem.status,
          first_seen: problem.first_seen,
          last_seen: problem.last_seen,
          resolved_at: problem.resolved_at
        }
      end

      def enforce_max_problems
        max = limits.max_problems
        return unless max

        total = Problem.count
        return unless total > max

        excess = total - max
        oldest_fps = Problem.order(last_seen: :asc).limit(excess).pluck(:fingerprint)
        return if oldest_fps.empty?

        Occurrence.where(fingerprint: oldest_fps).delete_all
        Problem.where(fingerprint: oldest_fps).delete_all
      end

      def enforce_max_server_events
        max = limits.max_server_events
        return unless max

        total = ServerEvent.count
        return unless total > max

        excess = total - max
        oldest_ids = ServerEvent.order(timestamp: :asc).limit(excess).pluck(:id)
        ServerEvent.where(id: oldest_ids).delete_all
      end
    end
  end
end
