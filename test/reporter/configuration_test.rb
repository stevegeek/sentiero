# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/configuration"

module Sentiero
  module Reporter
    class ConfigurationTest < Minitest::Test
      def test_defaults
        c = Configuration.new
        assert_nil c.endpoint
        assert_nil c.ingest_key
        assert_nil c.project
        assert_equal true, c.enabled
        assert_equal true, c.async
        assert_equal [], c.filter_keys
        assert_equal Scrubber::DEFAULT_KEYS, c.default_filter_keys
        refute_same Scrubber::DEFAULT_KEYS, c.default_filter_keys, "default is a mutable copy, not the frozen constant"
        assert_equal 100, c.max_queue
        assert_equal "sentiero_sid", c.session_cookie_name
        assert_equal "sentiero_wid", c.window_cookie_name
        assert_operator c.open_timeout, :>, 0
        assert_operator c.read_timeout, :>, 0
        assert_equal [], c.ignore_exceptions
        assert_nil c.before_notify
      end

      def test_configured_predicate
        c = Configuration.new
        refute c.configured?
        c.endpoint = "http://x"
        c.ingest_key = "k"
        c.project = "p"
        assert c.configured?
      end

      def test_active_requires_enabled_and_configured
        c = Configuration.new
        c.endpoint = "http://x"
        c.ingest_key = "k"
        c.project = "p"
        assert c.active?
        c.enabled = false
        refute c.active?
      end
    end
  end
end
