# frozen_string_literal: true

require "test_helper"

module Sentiero
  # Covers Configuration#session_idle_timeout / #session_max_age: the values
  # are serialized straight into the client's rotation math (see script_tag.rb
  # and frontend/src/session_config.js), so a bad value must fall back to the
  # default rather than reach the browser as NaN/0/negative.
  class SessionRotationConfigTest < Minitest::Test
    def teardown = Sentiero.reset_configuration!

    def test_defaults
      assert_equal 21_600, Sentiero.configuration.session_idle_timeout
      assert_equal 604_800, Sentiero.configuration.session_max_age
    end

    def test_accepts_a_positive_numeric_value
      Sentiero.configure do |c|
        c.session_idle_timeout = 60
        c.session_max_age = 120
      end

      assert_equal 60, Sentiero.configuration.session_idle_timeout
      assert_equal 120, Sentiero.configuration.session_max_age
    end

    def test_non_positive_values_fall_back_to_the_default
      Sentiero.configure do |c|
        c.session_idle_timeout = 0
        c.session_max_age = -1
      end

      assert_equal 21_600, Sentiero.configuration.session_idle_timeout
      assert_equal 604_800, Sentiero.configuration.session_max_age
    end

    def test_non_numeric_values_fall_back_to_the_default
      Sentiero.configure do |c|
        c.session_idle_timeout = "60"
        c.session_max_age = nil
      end

      assert_equal 21_600, Sentiero.configuration.session_idle_timeout
      assert_equal 604_800, Sentiero.configuration.session_max_age
    end

    def test_infinite_or_nan_values_fall_back_to_the_default
      Sentiero.configure do |c|
        c.session_idle_timeout = Float::INFINITY
        c.session_max_age = Float::NAN
      end

      assert_equal 21_600, Sentiero.configuration.session_idle_timeout
      assert_equal 604_800, Sentiero.configuration.session_max_age
    end
  end
end
