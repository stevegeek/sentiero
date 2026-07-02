# frozen_string_literal: true

require "test_helper"

# Minimal Roda stub for testing the plugin without requiring the roda gem.
# The plugin file (lib/sentiero/roda.rb) reopens `class Roda` and defines
# modules under RodaPlugins. We provide just enough structure here.
# Guarded so it won't conflict if the real roda gem is loaded.
unless defined?(::Roda)
  class Roda
    module RodaPlugins
      @plugins = {}

      def self.register_plugin(name, mod)
        @plugins[name] = mod
      end

      def self.plugins
        @plugins
      end
    end

    def self.plugin(name, **opts)
      mod = RodaPlugins.plugins[name]
      raise "Unknown plugin: #{name}" unless mod

      mod.configure(self, **opts) if mod.respond_to?(:configure)

      include mod::InstanceMethods if defined?(mod::InstanceMethods)
      request_class.include mod::RequestMethods if defined?(mod::RequestMethods)
    end

    def self.request_class
      @request_class ||= Class.new
    end
  end
end

require "sentiero/roda"

class RodaPluginTest < Minitest::Test
  def setup
    Sentiero.reset_configuration!
  end

  def teardown
    Sentiero.reset_configuration!
  end

  def test_plugin_is_registered
    assert Roda::RodaPlugins.plugins[:sentiero],
      "Expected :sentiero plugin to be registered"
  end

  def test_configure_sets_known_configuration_keys
    Roda::RodaPlugins::Sentiero.configure(Roda,
      store: Sentiero::Stores::Memory.new,
      cors_origins: ["https://example.com"],
      flush_interval_ms: 5_000,
      flush_event_threshold: 30,
      max_events_per_page: 500,
      recorder_options: {customOpt: true})

    config = Sentiero.configuration
    assert_kind_of Sentiero::Stores::Memory, config.store
    assert_equal ["https://example.com"], config.cors_origins
    assert_equal 5_000, config.flush_interval_ms
    assert_equal 30, config.flush_event_threshold
    assert_equal 500, config.max_events_per_page
    assert_equal({customOpt: true}, config.recorder_options)
  end

  def test_configure_ignores_unknown_keys
    Sentiero.configure { |c| c.flush_interval_ms = 10_000 }

    # Passing unknown keys should not raise and should not change config
    Roda::RodaPlugins::Sentiero.configure(Roda,
      unknown_key: "malicious",
      another_bad_key: 42)

    assert_equal 10_000, Sentiero.configuration.flush_interval_ms
  end

  def test_configure_rejects_arbitrary_method_calls_via_key_filtering
    # Ensure that keys outside CONFIGURATION_KEYS cannot invoke arbitrary
    # methods via public_send (e.g. trying to call `class=` or `freeze`)
    Roda::RodaPlugins::Sentiero.configure(Roda,
      class: "EvilClass",
      freeze: true,
      instance_variable_set: "@hacked")

    # Config should remain unchanged
    assert_nil Sentiero.configuration.store
  end

  def test_request_methods_module_defines_sentiero_events
    assert_method_defined(Roda::RodaPlugins::Sentiero::RequestMethods, :sentiero_events)
  end

  def test_request_methods_module_defines_sentiero_dashboard
    assert_method_defined(Roda::RodaPlugins::Sentiero::RequestMethods, :sentiero_dashboard)
  end

  def test_instance_methods_module_defines_sentiero_script_tag
    assert_method_defined(Roda::RodaPlugins::Sentiero::InstanceMethods, :sentiero_script_tag)
  end

  def test_sentiero_script_tag_delegates_to_script_tag_render
    Sentiero.configure { |c| c.store = Sentiero::Stores::Memory.new }

    obj = Object.new
    obj.extend(Roda::RodaPlugins::Sentiero::InstanceMethods)

    html = obj.sentiero_script_tag(events_url: "/test/events")

    assert_includes html, "sentiero-config"
    assert_includes html, "/test/events"
    assert_match %r{recorder-[A-Za-z0-9]+\.js}, html
  end

  def test_sentiero_script_tag_with_custom_recorder_url
    Sentiero.configure { |c| c.store = Sentiero::Stores::Memory.new }

    obj = Object.new
    obj.extend(Roda::RodaPlugins::Sentiero::InstanceMethods)

    html = obj.sentiero_script_tag(events_url: "/events", recorder_url: "/custom/rec.js")

    assert_includes html, "/custom/rec.js"
    refute_includes html, "vendor/recorder.js"
  end

  def test_configure_with_auth_callback
    callback = ->(env) { env["HTTP_AUTHORIZATION"] == "Bearer secret" }

    Roda::RodaPlugins::Sentiero.configure(Roda, auth_callback: callback)

    assert_equal callback, Sentiero.configuration.auth_callback
  end

  private

  def assert_method_defined(mod, method_name)
    assert mod.method_defined?(method_name),
      "Expected #{mod} to define #{method_name}"
  end
end
