# frozen_string_literal: true

require "json"
require_relative "redaction"
require_relative "reporter/configuration"
require_relative "reporter/normalizer"
require_relative "reporter/context"
require_relative "reporter/report_context"
require_relative "reporter/scrubber"
require_relative "reporter/dispatcher"
require_relative "reporter/http_transport"
require_relative "reporter/null_transport"
require_relative "reporter/log_transport"
require_relative "reporter/test_transport"

module Sentiero
  # Client SDK for reporting exceptions and custom events to a (remote) Sentiero
  # ingest. Every public method is fail-safe: it never raises into the host app.
  module Reporter
    # Guards lazy creation/teardown of the shared dispatcher (which spawns a
    # background thread + queue) so a concurrent cold start can't build two.
    RUNTIME_LOCK = Mutex.new

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
        reset_runtime!
        configuration
      end

      def reset!
        RUNTIME_LOCK.synchronize do
          shutdown
          @configuration = Configuration.new
          @dispatcher = nil
          @scrubber = nil
        end
      end

      def notify(exception, context: {})
        return unless configuration.active?
        return if ignored?(exception)

        payload = run_before_notify(build_error_payload(exception, build_report_context(context)))
        return if payload.nil?

        dispatcher.enqueue("errors", payload)
        nil
      rescue => e
        warn "[Sentiero::Reporter] notify failed: #{e.class}: #{e.message}"
        nil
      end

      def track(name, level: "info", session_id: nil, **payload)
        return unless configuration.active?

        dispatcher.enqueue("track", build_track_event(name, level, session_id, payload))
        nil
      rescue => e
        warn "[Sentiero::Reporter] track failed: #{e.class}: #{e.message}"
        nil
      end

      # Per-thread context. Stored as a Context (string-keyed by construction)
      # so readback is consistently string-keyed.
      def context
        context_store.to_h
      end

      def add_context(hash)
        self.fiber_local_context = context_store.merge(hash)
      end

      def with_context(hash)
        previous = context_store
        self.fiber_local_context = context_store.merge(hash)
        yield
      ensure
        self.fiber_local_context = previous
      end

      def clear_context
        self.fiber_local_context = Context.new
      end

      def flush
        @dispatcher&.flush
      end

      def shutdown
        @dispatcher&.shutdown
      end

      private

      def context_key
        :sentiero_reporter_context
      end

      def fiber_local_context
        Thread.current[context_key]
      end

      def fiber_local_context=(value)
        Thread.current[context_key] = value
      end

      def context_store
        self.fiber_local_context ||= Context.new
      end

      # ignore_exceptions entries are matched as Class (is_a?) or String class-name.
      def ignored?(exception)
        configuration.ignore_exceptions.any? do |matcher|
          case matcher
          when Module
            exception.is_a?(matcher)
          when String
            exception.class.ancestors.any? { |a| a.name == matcher }
          else
            false
          end
        end
      rescue => e
        warn "[Sentiero::Reporter] ignore_exceptions check failed: #{e.class}: #{e.message}"
        false
      end

      def build_report_context(context)
        report_ctx = ReportContext.new(context_store.merge(context))
        meta = report_ctx.metadata
        meta["environment"] = configuration.environment if configuration.environment
        meta["release"] = configuration.release if configuration.release
        report_ctx
      end

      def build_error_payload(exception, report_ctx)
        config = redaction_config
        payload = {
          "exception_class" => exception.class.name,
          "message" => Redaction.redact_text(exception.message.to_s, config),
          "backtrace" => Array(exception.backtrace).map { |frame| Redaction.redact_text(frame.to_s, config) },
          "context" => Redaction.deep_redact_strings(scrubber.scrub(report_ctx.metadata), config),
          "timestamp" => Time.now.to_f,
          "platform" => "ruby"
        }
        payload["session_id"] = report_ctx.session_id if report_ctx.session_id
        payload["window_id"] = report_ctx.window_id if report_ctx.window_id
        payload
      end

      # An explicit session_id wins; otherwise fall back to the thread context.
      def build_track_event(name, level, session_id, payload)
        scrubbed = scrubber.scrub(Normalizer.stringify_shallow(payload))
        event = {
          "name" => name.to_s,
          "level" => level.to_s,
          "payload" => Redaction.deep_redact_strings(scrubbed, redaction_config),
          "timestamp" => Time.now.to_f
        }
        session_id ||= context_store["session_id"]
        event["session_id"] = session_id if session_id
        event
      end

      # Returns the (possibly mutated) report, or nil to drop it when the hook
      # returns false/nil.
      def run_before_notify(payload)
        hook = configuration.before_notify
        return payload unless hook

        result = hook.call(payload)
        return if result == false || result.nil?
        result.is_a?(Hash) ? result : payload
      rescue => e
        warn "[Sentiero::Reporter] before_notify failed: #{e.class}: #{e.message}"
        payload
      end

      def scrubber
        @scrubber || RUNTIME_LOCK.synchronize { @scrubber ||= Scrubber.new(configuration.default_filter_keys + configuration.filter_keys) }
      end

      # Defaults when core isn't loaded, so a standalone reporter client still redacts.
      def redaction_config
        Sentiero.respond_to?(:configuration) ? Sentiero.configuration.redaction : Redaction::Config.new
      end

      def dispatcher
        @dispatcher || RUNTIME_LOCK.synchronize { @dispatcher ||= Dispatcher.new(transport, async: configuration.async, max_queue: configuration.max_queue) }
      end

      def transport
        configuration.transport || HttpTransport.new(
          endpoint: configuration.endpoint,
          ingest_key: configuration.ingest_key,
          open_timeout: configuration.open_timeout,
          read_timeout: configuration.read_timeout
        )
      end

      def reset_runtime!
        RUNTIME_LOCK.synchronize do
          shutdown
          @dispatcher = nil
          @scrubber = nil
        end
      end
    end
  end
end
