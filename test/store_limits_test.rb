# frozen_string_literal: true

require "test_helper"

module Sentiero
  class StoreLimitsTest < Minitest::Test
    def teardown = Sentiero.reset_configuration!

    def test_new_uses_defaults_and_ignores_global_config
      Sentiero.configuration.max_sessions = 7
      limits = Store::Limits.new
      assert_nil limits.max_sessions, "default is unlimited, not the global value"
      assert_equal 5_000, limits.analytics_max_scan_sessions
    end

    def test_from_configuration_reads_global_caps
      Sentiero.configuration.max_sessions = 7
      Sentiero.configuration.analytics_max_scan_sessions = 42

      limits = Store::Limits.from_configuration
      assert_equal 7, limits.max_sessions
      assert_equal 42, limits.analytics_max_scan_sessions
    end

    def test_explicit_overrides_are_independent_of_global
      limits = Store::Limits.new(max_sessions: 3)
      Sentiero.configuration.max_sessions = 99
      assert_equal 3, limits.max_sessions
    end

    def test_unknown_limit_is_rejected
      assert_raises(ArgumentError) { Store::Limits.new(bogus: 1) }
    end

    # Decoupling guarantee: a store enforces its injected caps with no global
    # config set, and two stores in one process hold different caps.
    def test_injected_limits_enforced_without_touching_global_config
      tight = Stores::Memory.new(limits: Store::Limits.new(max_sessions: 1))
      loose = Stores::Memory.new(limits: Store::Limits.new(max_sessions: 3))

      4.times do |i|
        ref = Sentiero::WindowRef.new("s#{i}", "w1")
        tight.save_events(ref, [{"timestamp" => i.to_f, "type" => 3}])
        loose.save_events(ref, [{"timestamp" => i.to_f, "type" => 3}])
      end

      assert_nil Sentiero.configuration.max_sessions, "global cap must be unset for this test"
      assert_equal 1, tight.list_sessions(limit: 10).size
      assert_equal 3, loose.list_sessions(limit: 10).size
    end

    # Composition root: assigning a store to the configuration binds the config's
    # caps to it (resolved at assignment, so set caps first).
    def test_configuration_store_assignment_binds_caps
      Sentiero.configuration.max_sessions = 2
      Sentiero.configuration.store = Stores::Memory.new

      3.times do |i|
        Sentiero.store.save_events(Sentiero::WindowRef.new("s#{i}", "w1"), [{"timestamp" => i.to_f, "type" => 3}])
      end
      assert_equal 2, Sentiero.store.list_sessions(limit: 10).size
    end
  end
end
