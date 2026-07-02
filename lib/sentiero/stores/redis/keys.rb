# frozen_string_literal: true

module Sentiero
  module Stores
    class Redis
      # Redis key layout for one Stores::Redis instance, namespaced under a
      # single prefix. See Stores::Redis for what each key holds.
      class Keys
        def initialize(prefix)
          @prefix = prefix
        end

        def events(session_id, window_id)
          "#{@prefix}events:#{session_id}:#{window_id}"
        end

        def session(session_id)
          "#{@prefix}session:#{session_id}"
        end

        def windows(session_id)
          "#{@prefix}windows:#{session_id}"
        end

        def sessions
          @sessions ||= "#{@prefix}sessions"
        end

        def problem(fingerprint)
          "#{@prefix}problem:#{fingerprint}"
        end

        def problems
          @problems ||= "#{@prefix}problems"
        end

        def problems_project(project)
          "#{@prefix}problems:project:#{project}"
        end

        def occurrences(fingerprint)
          "#{@prefix}occurrences:#{fingerprint}"
        end

        def session_occurrences(session_id)
          "#{@prefix}session_occurrences:#{session_id}"
        end

        def server_events
          @server_events ||= "#{@prefix}server_events"
        end

        def server_events_project(project)
          "#{@prefix}server_events:project:#{project}"
        end
      end
    end
  end
end
