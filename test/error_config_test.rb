# frozen_string_literal: true

require "test_helper"

class ErrorConfigTest < Minitest::Test
  def teardown
    Sentiero.reset_configuration!
  end

  def test_max_problems_default
    assert_equal 5_000, Sentiero.configuration.max_problems
  end

  def test_max_server_events_default
    assert_equal 50_000, Sentiero.configuration.max_server_events
  end

  def test_max_problems_is_settable
    Sentiero.configuration.max_problems = 500
    assert_equal 500, Sentiero.configuration.max_problems
  end

  def test_max_server_events_is_settable
    Sentiero.configuration.max_server_events = 1000
    assert_equal 1000, Sentiero.configuration.max_server_events
  end
end
