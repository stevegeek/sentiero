# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/dispatcher"
require "net/http"

module Sentiero
  module Reporter
    class DispatcherTest < Minitest::Test
      class RecordingTransport
        attr_reader :calls
        def initialize = (@calls = [])
        def post(path, payload) = @calls << [path, payload]
      end

      class RaisingTransport
        def post(_path, _payload) = raise "boom"
      end

      class HttpResponseTransport
        def initialize(response) = (@response = response)
        def post(_path, _payload) = @response
      end

      def test_sync_delivers_immediately
        t = RecordingTransport.new
        d = Dispatcher.new(t, async: false, max_queue: 10)
        d.enqueue("errors", {"a" => 1})
        assert_equal [["errors", {"a" => 1}]], t.calls
      end

      def test_sync_swallows_transport_errors
        d = Dispatcher.new(RaisingTransport.new, async: false, max_queue: 10)
        # must not raise
        assert_nil d.enqueue("errors", {})
      end

      def test_async_delivers_after_flush
        t = RecordingTransport.new
        d = Dispatcher.new(t, async: true, max_queue: 10)
        d.enqueue("errors", {"a" => 1})
        d.flush
        assert_equal [["errors", {"a" => 1}]], t.calls
      ensure
        d&.shutdown
      end

      def test_deliver_warns_on_http_error_response
        response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
        d = Dispatcher.new(HttpResponseTransport.new(response), async: false, max_queue: 10)
        _out, err = capture_io { d.enqueue("errors", {}) }
        assert_match(/\[Sentiero::Reporter\] delivery rejected: HTTP 401 for errors/, err)
      end

      def test_deliver_warns_once_per_process_on_repeated_errors
        response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
        d = Dispatcher.new(HttpResponseTransport.new(response), async: false, max_queue: 10)
        _out, err = capture_io { 3.times { d.enqueue("errors", {}) } }
        assert_equal 1, err.scan("delivery rejected").size
      end

      def test_deliver_stays_quiet_on_2xx
        response = Net::HTTPOK.new("1.1", "200", "OK")
        d = Dispatcher.new(HttpResponseTransport.new(response), async: false, max_queue: 10)
        _out, err = capture_io { d.enqueue("errors", {}) }
        assert_empty err
      end

      def test_deliver_stays_quiet_for_non_http_transports
        # Null/Log/Test transports return nil/arrays — the respond_to?(:code)
        # guard must keep them warning-free.
        d = Dispatcher.new(RecordingTransport.new, async: false, max_queue: 10)
        _out, err = capture_io { d.enqueue("errors", {}) }
        assert_empty err
      end

      def test_async_drops_when_queue_full_and_counts
        # A transport that blocks so the queue fills up.
        gate = Queue.new
        slow = Object.new
        slow.define_singleton_method(:post) { |_p, _pl| gate.pop }
        d = Dispatcher.new(slow, async: true, max_queue: 1)
        5.times { d.enqueue("errors", {}) }
        assert_operator d.dropped, :>, 0
      ensure
        10.times { gate << :go }
        d&.shutdown
      end
    end
  end
end
