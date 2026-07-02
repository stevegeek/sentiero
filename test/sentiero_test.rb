# frozen_string_literal: true

require "test_helper"

class SentieroTest < Minitest::Test
  def teardown
    Sentiero.reset_configuration!
  end

  def test_configure_sets_configuration_values
    Sentiero.configure do |c|
      c.flush_interval_ms = 5_000
      c.flush_event_threshold = 25
    end

    assert_equal 5_000, Sentiero.configuration.flush_interval_ms
    assert_equal 25, Sentiero.configuration.flush_event_threshold
  end

  def test_store_raises_when_no_store_configured
    error = assert_raises(Sentiero::Error) { Sentiero.store }
    assert_match(/No store configured/, error.message)
  end

  def test_store_returns_configured_store
    memory_store = Sentiero::Stores::Memory.new

    Sentiero.configure do |c|
      c.store = memory_store
    end

    assert_same memory_store, Sentiero.store
  end

  def test_reset_configuration_restores_defaults
    Sentiero.configure do |c|
      c.store = Sentiero::Stores::Memory.new
      c.flush_interval_ms = 999
      c.mask_all_inputs = false
      c.block_selector = ".custom"
    end

    Sentiero.reset_configuration!

    assert_nil Sentiero.configuration.store
    assert_equal 10_000, Sentiero.configuration.flush_interval_ms
    assert_equal 50, Sentiero.configuration.flush_event_threshold
    assert_equal 1_000, Sentiero.configuration.max_events_per_page
    assert_equal({}, Sentiero.configuration.recorder_options)
    assert_equal([], Sentiero.configuration.cors_origins)
    assert_nil Sentiero.configuration.auth_callback
    assert_equal true, Sentiero.configuration.mask_all_inputs
    assert_equal({}, Sentiero.configuration.mask_input_options)
    assert_equal "[data-rr-block]", Sentiero.configuration.block_selector
    assert_equal "[data-rr-mask]", Sentiero.configuration.mask_text_selector
    assert_equal "[data-rr-ignore]", Sentiero.configuration.ignore_selector
    assert_equal({scroll: 150, input: "last"}, Sentiero.configuration.sampling)
    assert_nil Sentiero.configuration.inline_stylesheet
    assert_nil Sentiero.configuration.checkout_every_n_ms
  end

  def test_analytics_and_privacy_config_defaults
    config = Sentiero::Configuration.new

    assert_equal false, config.capture_web_vitals
    assert_equal 5000, config.analytics_max_scan_sessions
    assert_equal false, config.user_opt_out
    assert_equal "sentiero_optout", config.opt_out_cookie_name
    assert_equal true, config.respect_gpc
    assert_nil config.retention_period
    assert_equal true, config.anonymize_ip
    assert_nil config.audit_log
    assert_equal false, config.shareable_replays
  end

  def test_track_custom_events_defaults_to_false
    assert_equal false, Sentiero.configuration.track_custom_events
  end

  def test_track_custom_events_is_configurable
    Sentiero.configure { |c| c.track_custom_events = true }
    assert_equal true, Sentiero.configuration.track_custom_events
  end

  def test_capture_clicks_defaults_to_false
    assert_equal false, Sentiero.configuration.capture_clicks
  end

  def test_capture_clicks_is_configurable
    Sentiero.configure { |c| c.capture_clicks = true }
    assert_equal true, Sentiero.configuration.capture_clicks
  end

  def test_effective_recorder_options_includes_privacy_defaults
    config = Sentiero::Configuration.new

    opts = config.effective_recorder_options

    assert_equal true, opts[:maskAllInputs]
    assert_equal "[data-rr-block]", opts[:blockSelector]
    assert_equal "[data-rr-mask]", opts[:maskTextSelector]
    assert_equal "[data-rr-ignore]", opts[:ignoreSelector]
    assert_equal({scroll: 150, input: "last"}, opts[:sampling])
  end

  def test_effective_recorder_options_merges_user_options
    config = Sentiero::Configuration.new
    config.mask_all_inputs = false
    config.recorder_options = {customOption: "value"}

    opts = config.effective_recorder_options

    assert_equal false, opts[:maskAllInputs]
    assert_equal "value", opts[:customOption]
  end

  def test_effective_recorder_options_enforces_password_masking
    config = Sentiero::Configuration.new
    # Attempt to disable password masking
    config.mask_input_options = {password: false, email: true}

    opts = config.effective_recorder_options

    assert_equal true, opts[:maskInputOptions][:password]
    assert_equal true, opts[:maskInputOptions][:email]
  end

  def test_effective_recorder_options_enforces_password_even_when_user_sets_non_hash
    config = Sentiero::Configuration.new
    # User sets mask_input_options to a non-hash value
    config.mask_input_options = "invalid"

    opts = config.effective_recorder_options

    assert_equal true, opts[:maskInputOptions][:password]
  end

  def test_first_class_attributes_take_precedence_over_recorder_options
    config = Sentiero::Configuration.new
    config.mask_all_inputs = false
    # Same key in escape hatch should be overridden
    config.recorder_options = {maskAllInputs: true}

    opts = config.effective_recorder_options

    assert_equal false, opts[:maskAllInputs]
  end

  def test_optional_attributes_omitted_when_nil
    config = Sentiero::Configuration.new

    opts = config.effective_recorder_options

    refute opts.key?(:inlineStylesheet)
    refute opts.key?(:checkoutEveryNms)
  end

  def test_optional_attributes_included_when_set
    config = Sentiero::Configuration.new
    config.inline_stylesheet = true
    config.checkout_every_n_ms = 5000

    opts = config.effective_recorder_options

    assert_equal true, opts[:inlineStylesheet]
    assert_equal 5000, opts[:checkoutEveryNms]
  end

  def test_effective_recorder_options_with_no_user_options
    config = Sentiero::Configuration.new

    opts = config.effective_recorder_options

    assert_equal({password: true}, opts[:maskInputOptions])
  end
end
