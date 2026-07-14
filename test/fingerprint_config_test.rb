# frozen_string_literal: true

require "test_helper"
require "sentiero/fingerprint"

class FingerprintConfigTest < Minitest::Test
  def setup
    @config = Sentiero::Fingerprint::Config.new
  end

  def test_default_platform_defaults_to_ruby
    assert_equal "ruby", @config.default_platform
  end

  def test_builtins_registered_at_construction
    assert_same Sentiero::Fingerprint::RUBY_NORMALIZER, @config.resolve("ruby")
    assert_same Sentiero::Fingerprint::CRYSTAL_NORMALIZER, @config.resolve("crystal")
    assert_same Sentiero::Fingerprint::GENERIC_NORMALIZER, @config.resolve("generic")
  end

  def test_resolve_absent_platform_falls_back_to_default_platform_normalizer
    assert_same Sentiero::Fingerprint::RUBY_NORMALIZER, @config.resolve(nil)
  end

  def test_resolve_blank_platform_falls_back_to_default_platform_normalizer
    assert_same Sentiero::Fingerprint::RUBY_NORMALIZER, @config.resolve("")
    assert_same Sentiero::Fingerprint::RUBY_NORMALIZER, @config.resolve("   ")
  end

  def test_resolve_registered_platform_returns_that_normalizer
    assert_same Sentiero::Fingerprint::CRYSTAL_NORMALIZER, @config.resolve("crystal")
  end

  def test_resolve_unregistered_platform_falls_back_to_generic
    assert_same Sentiero::Fingerprint::GENERIC_NORMALIZER, @config.resolve("php")
  end

  def test_default_platform_is_settable_and_changes_absent_platform_resolution
    custom = ->(frame) { frame }
    @config.register("php", custom)
    @config.default_platform = "php"

    assert_same custom, @config.resolve(nil)
  end

  def test_default_platform_as_symbol_resolves_to_registered_normalizer
    # default_platform is stored unchanged; resolve must coerce it with
    # .to_s to match the string keys register() stores, the same way tiers
    # 2/3 coerce the incoming `platform` argument.
    @config.default_platform = :crystal

    assert_same Sentiero::Fingerprint::CRYSTAL_NORMALIZER, @config.resolve(nil)
  end

  def test_default_platform_set_to_unregistered_name_falls_back_to_ruby_normalizer
    # Documented fallback: an operator can misconfigure default_platform to a
    # name that was never registered; absent/blank platform resolution must
    # not raise and must fall back to RUBY_NORMALIZER.
    @config.default_platform = "cobol"

    assert_same Sentiero::Fingerprint::RUBY_NORMALIZER, @config.resolve(nil)
  end

  def test_register_overrides_a_builtin
    custom = ->(frame) { frame.upcase }
    @config.register("ruby", custom)

    assert_same custom, @config.resolve("ruby")
  end

  def test_register_adds_a_new_platform
    custom = ->(frame) { frame }
    @config.register("php", custom)

    assert_same custom, @config.resolve("php")
  end

  def test_register_accepts_any_callable
    callable_object = Class.new {
      def call(frame)
        frame
      end
    }.new
    @config.register("weird", callable_object)

    assert_same callable_object, @config.resolve("weird")
  end
end

class FingerprintConfigIntegrationTest < Minitest::Test
  def teardown
    Sentiero.reset_configuration!
  end

  def test_default_fingerprint_config
    assert_instance_of Sentiero::Fingerprint::Config, Sentiero.configuration.fingerprint
    assert_equal "ruby", Sentiero.configuration.fingerprint.default_platform
  end

  def test_fingerprint_has_no_writer
    refute_respond_to Sentiero.configuration, :fingerprint=
  end
end
