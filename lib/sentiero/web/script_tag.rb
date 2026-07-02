# frozen_string_literal: true

require "json"
require_relative "escaping"

module Sentiero
  module Web
    module ScriptTag
      extend Escaping

      def self.render(events_url:, recorder_url: nil)
        config = Sentiero.configuration

        recorder_url ||= default_recorder_url(events_url)

        json_data = {
          eventsUrl: events_url,
          flushIntervalMs: config.flush_interval_ms,
          flushEventThreshold: config.flush_event_threshold,
          recorderOptions: config.effective_recorder_options,
          crossTabSessions: config.cross_tab_sessions,
          redaction: config.redaction.to_client_hash,
          # Seconds on the Ruby side (matches retention_period's unit); ms on
          # the wire so the client can compare directly against Date.now().
          sessionIdleTimeoutMs: config.session_idle_timeout * 1000,
          sessionMaxAgeMs: config.session_max_age * 1000
        }
        json_data[:captureMetadata] = true if config.capture_metadata
        json_data[:captureErrors] = true if config.capture_errors
        json_data[:trackNavigation] = true if config.track_navigation
        json_data[:trackCustomEvents] = true if config.track_custom_events
        json_data[:captureWebVitals] = true if config.capture_web_vitals
        json_data[:captureClicks] = true if config.capture_clicks
        json_data[:trackForms] = true if config.track_forms
        json_data[:optOutCookieName] = config.opt_out_cookie_name if config.user_opt_out
        json_data[:respectGpc] = true if config.respect_gpc

        config_json = JSON.generate(json_data)

        safe_json = escape_json(config_json)
        escaped_recorder_url = escape_html(recorder_url.to_s)

        <<~HTML
          <script type="application/json" id="sentiero-config">#{safe_json}</script>
          <script src="#{escaped_recorder_url}"></script>
        HTML
      end

      def self.default_recorder_url(events_url)
        base = events_url.sub(%r{/events\z}, "")
        Sentiero::Web::Manifest.asset_path("recorder", base)
      end

      private_class_method :default_recorder_url
    end
  end
end
