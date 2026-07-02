# frozen_string_literal: true

require_relative "scrubber"

module Sentiero
  module Reporter
    class Configuration
      attr_accessor :endpoint, :ingest_key, :project, :environment, :release,
        :default_filter_keys, :filter_keys, :enabled, :async, :max_queue,
        :open_timeout, :read_timeout,
        :session_cookie_name, :window_cookie_name,
        :transport,
        :before_notify

      attr_reader :ignore_exceptions

      def initialize
        @endpoint = nil
        @ingest_key = nil
        @project = nil
        @environment = nil
        @release = nil
        @default_filter_keys = Scrubber::DEFAULT_KEYS.dup
        @filter_keys = []
        @enabled = true
        @async = true
        @max_queue = 100
        @open_timeout = 2
        @read_timeout = 3
        @session_cookie_name = "sentiero_sid"
        @window_cookie_name = "sentiero_wid"
        @transport = nil
        @ignore_exceptions = []
        @before_notify = nil
      end

      def ignore_exceptions=(value)
        @ignore_exceptions = Array(value)
      end

      def configured?
        !endpoint.nil? && !ingest_key.nil? && !project.nil?
      end

      def active?
        enabled && configured?
      end
    end
  end
end
