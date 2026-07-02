# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/null_transport"
require "sentiero/reporter/log_transport"
require "sentiero/reporter/test_transport"
require "stringio"

module Sentiero
  module Reporter
    class TransportsTest < Minitest::Test
      def test_null_transport_responds_to_post_and_drops
        t = NullTransport.new
        assert_nil t.post("errors", {"a" => 1})
      end

      def test_null_transport_counts_deliveries
        t = NullTransport.new
        t.post("errors", {})
        t.post("track", {})
        assert_equal 2, t.delivered
      end

      def test_log_transport_writes_each_delivery
        io = StringIO.new
        t = LogTransport.new(io: io)
        t.post("errors", {"exception_class" => "RuntimeError"})
        out = io.string
        assert_match(/Sentiero::Reporter/, out)
        assert_match(/errors/, out)
        assert_match(/RuntimeError/, out)
      end

      def test_log_transport_uses_logger_when_given
        logged = []
        logger = Object.new
        logger.define_singleton_method(:info) { |msg| logged << msg }
        t = LogTransport.new(logger: logger)
        t.post("track", {"name" => "signup"})
        assert_equal 1, logged.size
        assert_match(/signup/, logged.first)
      end

      def test_test_transport_records_deliveries
        t = TestTransport.new
        t.post("errors", {"a" => 1})
        t.post("track", {"b" => 2})
        assert_equal [["errors", {"a" => 1}], ["track", {"b" => 2}]], t.deliveries
        assert_equal [{"a" => 1}], t.payloads_for("errors")
      end
    end
  end
end
