# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter"

module Sentiero
  class ReporterTest < Minitest::Test
    class Recording
      attr_reader :calls
      def initialize = (@calls = [])
      def post(path, payload) = @calls << [path, payload]
    end

    def setup
      @transport = Recording.new
      Reporter.configure do |c|
        c.endpoint = "http://collector.test"
        c.ingest_key = "k"
        c.project = "app"
        c.environment = "test"
        c.release = "v1"
        c.async = false
        c.transport = @transport
      end
    end

    def teardown
      Reporter.reset!
    end

    def last(path)
      @transport.calls.reverse.find { |p, _| p == path }&.last
    end

    def test_notify_sends_exception_payload
      begin
        raise ArgumentError, "bad thing"
      rescue => e
        Reporter.notify(e)
      end
      payload = last("errors")
      assert_equal "ArgumentError", payload["exception_class"]
      assert_equal "bad thing", payload["message"]
      assert_kind_of Array, payload["backtrace"]
      assert_equal "test", payload["context"]["environment"]
      assert_equal "v1", payload["context"]["release"]
      refute payload.key?("project") # project derived from key server-side
      assert_operator payload["timestamp"], :>, 0
    end

    def test_notify_scrubs_context
      Reporter.notify(RuntimeError.new("x"), context: {"password" => "hunter2", "ok" => "v"})
      payload = last("errors")
      assert_equal "[FILTERED]", payload["context"]["password"]
      assert_equal "v", payload["context"]["ok"]
    end

    def test_filter_keys_are_additive_to_defaults
      Reporter.configure { |c| c.filter_keys = ["badge"] }
      Reporter.notify(RuntimeError.new("x"), context: {"badge" => "b", "password" => "p", "ok" => "v"})
      payload = last("errors")
      assert_equal "[FILTERED]", payload["context"]["badge"]
      assert_equal "[FILTERED]", payload["context"]["password"]
      assert_equal "v", payload["context"]["ok"]
    end

    def test_default_filter_keys_can_be_overridden_to_drop_a_default
      Reporter.configure { |c| c.default_filter_keys = c.default_filter_keys - ["password"] }
      Reporter.notify(RuntimeError.new("x"), context: {"password" => "p", "token" => "t"})
      payload = last("errors")
      assert_equal "p", payload["context"]["password"], "removed default is no longer scrubbed"
      assert_equal "[FILTERED]", payload["context"]["token"]
    end

    def test_notify_pulls_session_id_from_context
      Reporter.notify(RuntimeError.new("x"), context: {session_id: "sess_1", window_id: "win_1"})
      payload = last("errors")
      assert_equal "sess_1", payload["session_id"]
      assert_equal "win_1", payload["window_id"]
      refute payload["context"].key?(:session_id)
      refute payload["context"].key?("session_id")
    end

    def test_track_uses_session_id_from_thread_context
      Reporter.with_context(session_id: "sess_ctx") do
        Reporter.track("evt")
      end
      assert_equal "sess_ctx", last("track")["session_id"]
    end

    def test_track_sends_event_payload
      Reporter.track("signup", level: "info", session_id: "sess_1", plan: "pro")
      payload = last("track")
      assert_equal "signup", payload["name"]
      assert_equal "info", payload["level"]
      assert_equal "sess_1", payload["session_id"]
      assert_equal "pro", payload["payload"]["plan"]
    end

    def test_track_scrubs_payload
      Reporter.track("x", token: "abc")
      assert_equal "[FILTERED]", last("track")["payload"]["token"]
    end

    def test_no_op_when_not_configured
      Reporter.reset!
      Reporter.configure { |c| c.transport = @transport } # not configured (no endpoint/key/project)
      Reporter.notify(RuntimeError.new("x"))
      assert_empty @transport.calls
    end

    def test_no_op_when_disabled
      Reporter.configuration.enabled = false
      Reporter.notify(RuntimeError.new("x"))
      assert_empty @transport.calls
    end

    def test_never_raises_even_if_transport_raises
      Reporter.configuration.transport = Object.new.tap do |o|
        o.define_singleton_method(:post) { |_p, _pl| raise "kaboom" }
      end
      # must not raise
      assert_nil Reporter.notify(RuntimeError.new("x"))
    end

    def test_with_context_merges_for_block
      Reporter.with_context(account: "acme") do
        Reporter.notify(RuntimeError.new("x"))
      end
      assert_equal "acme", last("errors")["context"]["account"]
    end

    # Context keys normalize to strings at the write boundary [review T1]:
    # symbol writes read back string-keyed, so notify/track only ever see
    # string keys.
    def test_context_readback_is_string_keyed
      Reporter.add_context(:plan => "pro", "region" => "eu")
      assert_equal({"plan" => "pro", "region" => "eu"}, Reporter.context)
    ensure
      Reporter.clear_context
    end

    def test_track_picks_up_symbol_written_session_id_from_context
      Reporter.add_context(session_id: "sess_sym")
      Reporter.track("evt")
      assert_equal "sess_sym", last("track")["session_id"]
    ensure
      Reporter.clear_context
    end

    class IgnoredError < StandardError; end

    class SubclassOfIgnored < IgnoredError; end

    def test_notify_skips_ignored_exception_by_class
      Reporter.configuration.ignore_exceptions = [IgnoredError]
      assert_nil Reporter.notify(IgnoredError.new("nope"))
      assert_empty @transport.calls
    end

    def test_notify_skips_ignored_exception_by_ancestor
      Reporter.configuration.ignore_exceptions = [IgnoredError]
      assert_nil Reporter.notify(SubclassOfIgnored.new("nope"))
      assert_empty @transport.calls
    end

    def test_notify_skips_ignored_exception_by_string_name
      Reporter.configuration.ignore_exceptions = ["Sentiero::ReporterTest::IgnoredError"]
      assert_nil Reporter.notify(IgnoredError.new("nope"))
      assert_empty @transport.calls
    end

    def test_notify_does_not_skip_unrelated_exception
      Reporter.configuration.ignore_exceptions = [IgnoredError]
      Reporter.notify(RuntimeError.new("yes"))
      refute_empty @transport.calls
    end

    def test_before_notify_returning_false_drops_report
      Reporter.configuration.before_notify = ->(_report) { false }
      assert_nil Reporter.notify(RuntimeError.new("x"))
      assert_empty @transport.calls
    end

    def test_before_notify_returning_nil_drops_report
      Reporter.configuration.before_notify = ->(report) { report && nil }
      assert_nil Reporter.notify(RuntimeError.new("x"))
      assert_empty @transport.calls
    end

    def test_before_notify_can_mutate_report
      Reporter.configuration.before_notify = lambda do |report|
        report["context"]["mutated"] = "yes"
        report["message"] = "rewritten"
        report
      end
      Reporter.notify(RuntimeError.new("original"))
      payload = last("errors")
      assert_equal "yes", payload["context"]["mutated"]
      assert_equal "rewritten", payload["message"]
    end

    def test_before_notify_failure_is_fail_safe_and_still_delivers
      Reporter.configuration.before_notify = ->(_report) { raise "boom in hook" }
      # must not raise; report still delivered (hook failure does not drop)
      assert_nil Reporter.notify(RuntimeError.new("x"))
      refute_empty @transport.calls
    end
  end
end
