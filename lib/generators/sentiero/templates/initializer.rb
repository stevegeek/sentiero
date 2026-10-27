# frozen_string_literal: true

# Sentiero configuration
#
# For full documentation, see: https://github.com/stevegeek/sentiero

Sentiero.configure do |config|
  # Store: defaults to ActiveRecord (Sentiero::Rails::Store) when using sentiero-rails.
  # You can switch to Redis or Memory stores if preferred:
  #   config.store = Sentiero::Stores::Memory.new
  #   config.store = Sentiero::Stores::Redis.new(redis: Redis.new)
  # config.store = Sentiero::Rails::Store.new

  # CORS origins: list of allowed origins for the events endpoint.
  # Required if your frontend is on a different domain.
  # config.cors_origins = ["https://yourapp.com"]

  # Maximum events accepted per single POST request (default: nil = unlimited).
  # config.max_events_per_request = 500

  # Maximum total events stored per session (oldest dropped when exceeded).
  # Enforced by the ActiveRecord, Memory, File, and SQLite stores. The Redis
  # store ignores it; cap session size there with the store's :ttl option.
  # config.max_events_per_session = 10_000

  # Maximum sessions stored (oldest evicted when exceeded).
  # Enforced by the ActiveRecord, Memory, File, and SQLite stores. The Redis
  # store ignores it; cap retention there with the store's :ttl option.
  # config.max_sessions = 1_000

  # Data retention: automatically purge sessions older than a given period.
  # Set the period in seconds, then schedule `rake sentiero:purge` from cron
  # or a job scheduler (e.g. Sidekiq::Cron, Clockwork, whenever).
  # config.retention_period = 90 * 24 * 3600 # 90 days

  # Recorder flush settings (milliseconds / event count).
  # config.flush_interval_ms = 10_000
  # config.flush_event_threshold = 50

  # Dashboard authentication (HTTP Basic).
  #
  # Enabled by default. Set the password in your environment:
  #   export SENTIERO_DASHBOARD_PASSWORD=...
  # The dashboard refuses to load (raises) until a non-blank password is set.
  # With no auth configured the dashboard fails closed (403); to serve it
  # unauthenticated anyway, remove this block and set
  # `config.allow_insecure_dashboard = true`.
  config.basic_auth = {
    user: "admin",
    password: ENV["SENTIERO_DASHBOARD_PASSWORD"]
  }

  # Alternative: app-session-based auth instead of HTTP Basic. Comment out
  # config.basic_auth above and set a callback returning true/false:
  #
  # config.auth_callback = ->(env) {
  #   env["warden"]&.user&.admin? || false
  # }
end

# Rails-specific configuration
# Sentiero::Rails.configure do |config|
#   # The URL where EventsApp is mounted (used by the sentiero_script_tag helper).
#   # config.events_url = "/sentiero/events"
#
#   # Server-side error reporter middleware is auto-inserted when the reporter is
#   # configured below. Set to false to opt out of the auto-install.
#   # config.reporter_middleware = true
# end

# Server-side Error Tracking (reporter)
#
# The reporter sends unhandled exceptions and custom events to a Sentiero
# ingest endpoint. When configured, the Rack middleware is auto-inserted into
# your app's middleware stack (zero-config capture). It also links server-side
# errors to front-end session replay via the sentiero_sid / sentiero_wid
# cookies. Uncomment and fill in to enable:
#
# Sentiero::Reporter.configure do |r|
#   r.endpoint = ENV["SENTIERO_ENDPOINT"]      # e.g. "https://sentiero.example.com"
#   r.ingest_key = ENV["SENTIERO_INGEST_KEY"]  # server-issued ingest key
#   r.project = "my-app"                        # project identifier
#   r.environment = Rails.env                   # "production", "staging", ...
#   r.release = ENV["GIT_SHA"]                  # optional release/version
#
#   # Don't report these (Class or "String" class-names; ancestors match too):
#   # r.ignore_exceptions = [ActiveRecord::RecordNotFound, "ActionController::RoutingError"]
#
#   # Mutate or drop a report before it is sent (return false/nil to drop):
#   # r.before_notify = ->(report) {
#   #   report["context"].delete("secret")
#   #   report
#   # }
#
#   # Redact context/payload keys before sending. Matching is case-insensitive
#   # and substring-based. filter_keys is added on top of the built-in defaults:
#   # r.filter_keys = [:api_secret, :otp]
#   #
#   # The built-in defaults (password, token, ssn, ...) seed default_filter_keys,
#   # which you can edit to relax the floor:
#   # r.default_filter_keys -= ["ssn"]
#
#   # Use a non-network transport in development/test:
#   # r.transport = Sentiero::Reporter::LogTransport.new   # logs would-be sends
#   # r.transport = Sentiero::Reporter::NullTransport.new  # drops everything
# end
