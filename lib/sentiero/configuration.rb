# frozen_string_literal: true

module Sentiero
  class Configuration
    attr_reader :store

    attr_accessor :cors_origins,
      :auth_callback,
      :flush_interval_ms,
      :flush_event_threshold,
      :max_events_per_page,
      :max_events_per_request,
      :max_sessions,
      :max_events_per_session,
      :max_problems,
      :max_server_events,
      :ingest_keys,
      :cross_tab_sessions,
      :capture_metadata,
      :capture_errors,
      :track_navigation,
      :track_custom_events,
      :capture_clicks,
      :track_forms,
      # snake_case rrweb recorder options; converted to camelCase for the frontend.
      :mask_all_inputs,
      :mask_input_options,
      :block_selector,
      :mask_text_selector,
      :ignore_selector,
      :sampling,
      :inline_stylesheet,
      :checkout_every_n_ms,
      # Raw camelCase hash passed to rrweb verbatim; first-class attributes above
      # take precedence for overlapping keys.
      :recorder_options,
      :capture_web_vitals,
      :analytics_max_scan_sessions,
      :user_opt_out,
      :opt_out_cookie_name,
      :respect_gpc,
      :retention_period,
      :anonymize_ip,
      :redaction,
      :audit_log,
      :shareable_replays,
      :basic_auth,
      # Escape hatch: serve the dashboard/analytics/monitoring UIs with NO auth
      # (see Configuration#initialize). Off by default so the UI fails closed.
      :allow_insecure_dashboard

    # session_idle_timeout / session_max_age have validating writers below (a
    # bad value here is serialized straight into client-side session-rotation
    # logic), so they're declared separately from the plain attr_accessor list.
    attr_reader :session_idle_timeout, :session_max_age

    ENFORCED_PRIVACY = {
      maskInputOptions: {password: true}
    }.freeze

    # Replay sessions follow a user journey, so the idle boundary is generous
    # (a lunch break shouldn't split a journey); max age is the hard cap that
    # keeps the identifier from living forever on never-idle tabs.
    DEFAULT_SESSION_IDLE_TIMEOUT = 6 * 60 * 60
    DEFAULT_SESSION_MAX_AGE = 7 * 24 * 60 * 60

    # Composition root for store caps: a store assigned to the configuration is
    # bound to the configuration's caps here, so the store itself never reads
    # global state. Set caps before assigning the store; inject explicit
    # Store::Limits on the store afterward to override.
    def store=(store)
      store.limits = Store::Limits.from_configuration(self) if store.respond_to?(:limits=)
      @store = store
    end

    # Reach the Rails / Reporter config from the one core object, e.g.
    # Sentiero.configure { |c| c.reporter.endpoint = "..." }. They remain separate
    # instances so the reporter stays usable as a standalone client.
    def reporter
      require_subsystem!("Sentiero::Reporter", 'require "sentiero/reporter"')
      Reporter.configuration
    end

    def rails
      require_subsystem!("Sentiero::Rails", "the sentiero-rails gem")
      Rails.configuration
    end

    private def require_subsystem!(const_name, hint)
      return if Object.const_defined?(const_name)

      raise Error, "#{const_name} is not loaded — #{hint} to configure it."
    end

    # A non-positive or non-numeric value would either disable rotation
    # (never expire) or break the client's Date.now() arithmetic once
    # serialized into the config JSON, so it silently falls back instead of
    # raising.
    def session_idle_timeout=(value)
      @session_idle_timeout = clamp_positive_seconds(value, DEFAULT_SESSION_IDLE_TIMEOUT)
    end

    def session_max_age=(value)
      @session_max_age = clamp_positive_seconds(value, DEFAULT_SESSION_MAX_AGE)
    end

    private def clamp_positive_seconds(value, default)
      (value.is_a?(Numeric) && value.finite? && value > 0) ? value : default
    end

    def initialize
      @store = nil
      @cors_origins = []
      @auth_callback = nil
      @flush_interval_ms = 10_000
      @flush_event_threshold = 50
      @max_events_per_page = 1_000
      @max_problems = 5_000
      @max_server_events = 50_000
      @ingest_keys = {}
      @cross_tab_sessions = true
      @capture_metadata = false
      @capture_errors = false
      @track_navigation = false
      @track_custom_events = false
      @capture_clicks = false
      @track_forms = false

      @mask_all_inputs = true
      @mask_input_options = {}
      @block_selector = "[data-rr-block]"
      @mask_text_selector = "[data-rr-mask]"
      @ignore_selector = "[data-rr-ignore]"
      @sampling = {scroll: 150, input: "last"}
      @inline_stylesheet = nil
      @checkout_every_n_ms = nil
      @recorder_options = {}

      @capture_web_vitals = false
      @analytics_max_scan_sessions = 5000
      @user_opt_out = false
      @opt_out_cookie_name = "sentiero_optout"
      @respect_gpc = true
      @retention_period = nil
      @session_idle_timeout = DEFAULT_SESSION_IDLE_TIMEOUT
      @session_max_age = DEFAULT_SESSION_MAX_AGE
      @redaction = Sentiero::Redaction::Config.new
      @anonymize_ip = true
      @audit_log = nil
      # Opt-in: a share file is a full session dump leaving the operator's
      # infrastructure, so export/import routes 404 until explicitly enabled.
      @shareable_replays = false
      @basic_auth = nil
      # The dashboard exposes recordings/analytics, so with neither basic_auth nor
      # auth_callback set it fails closed (403). Set true to opt into serving it
      # unauthenticated (e.g. behind a trusted proxy or in local dev).
      @allow_insecure_dashboard = false
    end

    def effective_recorder_options
      first_class = {
        maskAllInputs: mask_all_inputs,
        maskInputOptions: mask_input_options,
        blockSelector: block_selector,
        maskTextSelector: mask_text_selector,
        ignoreSelector: ignore_selector,
        sampling: sampling
      }

      first_class[:inlineStylesheet] = inline_stylesheet unless inline_stylesheet.nil?
      first_class[:checkoutEveryNms] = checkout_every_n_ms unless checkout_every_n_ms.nil?

      recorder_options
        .merge(first_class)
        .merge(ENFORCED_PRIVACY) { |_key, existing, enforced|
          if enforced.is_a?(Hash)
            (existing.is_a?(Hash) ? existing : {}).merge(enforced)
          else
            enforced
          end
        }
    end
  end
end
