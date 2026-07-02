# frozen_string_literal: true

require_relative "test_helper"
require "sentiero/reporter"

# Integration test for the Rails engine's reporter middleware auto-install.
# We exercise Engine.insert_reporter_middleware (the logic run by the
# "sentiero.reporter_middleware" initializer at boot) against a fake app whose
# middleware stack records inserts, so we can assert both the configured and
# unconfigured branches without re-booting the dummy app.
class Sentiero::Rails::ReporterMiddlewareTest < Minitest::Test
  class FakeMiddlewareStack
    attr_reader :used

    def initialize
      @used = []
    end

    def use(klass, *args)
      @used << klass
    end

    def include?(klass)
      @used.include?(klass)
    end
  end

  class FakeApp
    attr_reader :middleware

    def initialize
      @middleware = FakeMiddlewareStack.new
    end
  end

  def setup = Sentiero.reset_all_configuration!

  def teardown = Sentiero.reset_all_configuration!

  def configure_reporter!
    Sentiero::Reporter.configure do |r|
      r.endpoint = "http://collector.test"
      r.ingest_key = "k"
      r.project = "app"
      r.async = false
      r.transport = Sentiero::Reporter::NullTransport.new
    end
  end

  def test_inserts_middleware_when_reporter_configured
    configure_reporter!
    app = FakeApp.new
    assert Sentiero::Rails::Engine.insert_reporter_middleware(app)
    assert app.middleware.include?(Sentiero::Reporter::Middleware)
  end

  # The fix: install at boot even when the reporter isn't configured yet, because
  # Reporter.configure runs in a later initializer. Reporter.notify no-ops until
  # active?, so installing early is safe and avoids the middleware never being added.
  def test_inserts_middleware_even_when_reporter_not_yet_configured
    app = FakeApp.new
    assert Sentiero::Rails::Engine.insert_reporter_middleware(app)
    assert app.middleware.include?(Sentiero::Reporter::Middleware)
  end

  def test_does_not_insert_when_opt_out_flag_false
    configure_reporter!
    Sentiero::Rails.configuration.reporter_middleware = false
    app = FakeApp.new
    refute Sentiero::Rails::Engine.insert_reporter_middleware(app)
    refute app.middleware.include?(Sentiero::Reporter::Middleware)
  end

  def test_real_dummy_app_inserts_middleware_by_default
    # The dummy app boots without the reporter configured; the middleware must
    # still be installed (opt-in flag defaults on) so reporting works once the
    # app configures the reporter at runtime.
    assert SentieroTest::Application.middleware.map(&:klass).include?(Sentiero::Reporter::Middleware)
  end
end
