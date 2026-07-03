# frozen_string_literal: true

require_relative "sentiero/version"
require_relative "sentiero/redaction"
require_relative "sentiero/configuration"
require_relative "sentiero/geo"
require_relative "sentiero/ip_anonymizer"
require_relative "sentiero/store"
require_relative "sentiero/erasure"
require_relative "sentiero/stores/memory"
require_relative "sentiero/web/events_app"
require_relative "sentiero/web/ingest_app"
require_relative "sentiero/web/errors_app"
require_relative "sentiero/web/track_app"
require_relative "sentiero/fingerprint"
require_relative "sentiero/web/assets_app"
require_relative "sentiero/web/manifest"
require_relative "sentiero/web/base_app"
require_relative "sentiero/web/basic_auth"
require_relative "sentiero/web/dashboard_app"
require_relative "sentiero/web/analytics_app"
require_relative "sentiero/web/monitoring_app"
require_relative "sentiero/web/script_tag"
require_relative "sentiero/analytics/analyzer"

module Sentiero
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # Resets the core config plus the Rails and Reporter configs when those
    # subsystems are loaded — one teardown for tests instead of three.
    def reset_all_configuration!
      reset_configuration!
      Sentiero::Rails.reset_configuration! if defined?(Sentiero::Rails) && Sentiero::Rails.respond_to?(:reset_configuration!)
      Sentiero::Reporter.reset! if defined?(Sentiero::Reporter) && Sentiero::Reporter.respond_to?(:reset!)
      configuration
    end

    def store
      configuration.store || raise(Error, "No store configured.")
    end

    def purge_expired!
      period = configuration.retention_period
      return unless period

      store.purge_older_than(period)
    end

    def erase_sessions(ids)
      Erasure.erase_sessions(store, ids)
    end

    def erase_where(since: nil, until_time: nil)
      Erasure.erase_where(store, since: since, until_time: until_time)
    end
  end
end
