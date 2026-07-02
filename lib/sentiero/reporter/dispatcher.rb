# frozen_string_literal: true

require "net/http"
require "concurrent/atomic/atomic_fixnum"

module Sentiero
  module Reporter
    # Delivers payloads to a transport, synchronously or via a bounded background
    # queue. Never raises into the caller; when the async queue is full new
    # payloads are dropped rather than blocking the host app.
    class Dispatcher
      # A latch pushed through the work queue by #flush; recognized by type.
      FlushLatch = Thread::Queue

      def dropped
        @dropped.value
      end

      def initialize(transport, async:, max_queue:)
        @transport = transport
        @async = async
        @dropped = Concurrent::AtomicFixnum.new(0) # incremented from concurrent enqueue callers
        @rejection_warned = false
        return unless @async

        @queue = SizedQueue.new(max_queue)
        @thread = Thread.new { run }
        @thread.name = "sentiero-reporter" if @thread.respond_to?(:name=)
      end

      def enqueue(path, payload)
        if @async
          begin
            @queue.push([path, payload], true) # non-block so ThreadError is raised if queue full
          rescue ThreadError
            @dropped.increment
          end
        else
          deliver([path, payload])
        end
        nil
      end

      # Blocks until every payload enqueued before this call has been delivered.
      # The latch rides the FIFO queue, so reaching it means all prior jobs are done.
      def flush
        return unless @async
        latch = FlushLatch.new
        @queue.push(latch)
        latch.pop
        nil
      end

      def shutdown
        return unless @async
        @queue.push(:stop)
        @thread.join(2)
      end

      private

      def run
        loop do
          job = @queue.pop
          case job
          when :stop then break
          when FlushLatch then job.push(true) # prior jobs all delivered; wake #flush
          else deliver(job)
          end
        end
      end

      def deliver((path, payload))
        response = @transport.post(path, payload)
        # Null/Log/Test transports return nil/arrays, not HTTP responses.
        if response.respond_to?(:code) && !response.is_a?(Net::HTTPSuccess)
          warn_rejected(response, path)
        end
      rescue => e
        warn "[Sentiero::Reporter] delivery failed: #{e.class}: #{e.message}"
      end

      # First occurrence only (one dispatcher per process in practice.)
      def warn_rejected(response, path)
        return if @rejection_warned
        @rejection_warned = true
        warn "[Sentiero::Reporter] delivery rejected: HTTP #{response.code} for #{path}"
      end
    end
  end
end
