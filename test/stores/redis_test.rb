# frozen_string_literal: true

require "test_helper"
require "store_contract_tests"
require "error_store_contract_tests"

require "dotenv"
Dotenv.load(".env.test")

begin
  require "redis"
  REDIS_URL = ENV.fetch("REDIS_URL", nil)
  REDIS_AVAILABLE = begin
    ::Redis.new(url: REDIS_URL).ping == "PONG"
  rescue
    false
  end
rescue LoadError
  REDIS_AVAILABLE = false
end

require "sentiero/stores/redis" if REDIS_AVAILABLE

module Sentiero
  module Stores
    class RedisTest < Minitest::Test
      include StoreContractTests
      include ErrorStoreContractTests

      TEST_PREFIX = "sentiero_test:"

      def create_store
        skip "Redis not available" unless REDIS_AVAILABLE

        @redis_client = ::Redis.new(url: REDIS_URL)
        cleanup_test_keys(@redis_client, TEST_PREFIX)

        Sentiero::Stores::Redis.new(redis: @redis_client, prefix: TEST_PREFIX)
      end

      def teardown
        if REDIS_AVAILABLE && @redis_client
          cleanup_test_keys(@redis_client, TEST_PREFIX)
        end
      end

      def test_ttl_is_applied_when_configured
        skip "Redis not available" unless REDIS_AVAILABLE

        redis_client = ::Redis.new(url: REDIS_URL)
        prefix = "sentiero_ttl_test:"
        cleanup_test_keys(redis_client, prefix)

        store = Sentiero::Stores::Redis.new(redis: redis_client, ttl: 300, prefix: prefix)
        store.save_events(Sentiero::WindowRef.new("s1", "w1"), [{"timestamp" => 1.0, "type" => "mouse", "data" => {}}])

        events_key = "#{prefix}events:s1:w1"
        session_key = "#{prefix}session:s1"
        windows_key = "#{prefix}windows:s1"

        events_ttl = redis_client.ttl(events_key)
        session_ttl = redis_client.ttl(session_key)
        windows_ttl = redis_client.ttl(windows_key)

        assert events_ttl > 0, "Expected events key to have TTL, got #{events_ttl}"
        assert events_ttl <= 300, "Expected events TTL <= 300, got #{events_ttl}"
        assert session_ttl > 0, "Expected session key to have TTL, got #{session_ttl}"
        assert session_ttl <= 300, "Expected session TTL <= 300, got #{session_ttl}"
        assert windows_ttl > 0, "Expected windows key to have TTL, got #{windows_ttl}"
        assert windows_ttl <= 300, "Expected windows TTL <= 300, got #{windows_ttl}"
      ensure
        if redis_client
          cleanup_test_keys(redis_client, prefix)
        end
      end

      # Regression: the problem upsert was a read-modify-write in Ruby, so
      # concurrent occurrences of the same fingerprint lost count increments.
      # The Lua upsert makes it atomic; each thread uses its own connection.
      def test_concurrent_occurrences_do_not_lose_count
        skip "Redis not available" unless REDIS_AVAILABLE

        prefix = "sentiero_occ_race_test:"
        cleanup_test_keys(::Redis.new(url: REDIS_URL), prefix)

        threads = 8
        per_thread = 25
        workers = Array.new(threads) do
          Thread.new do
            store = Sentiero::Stores::Redis.new(redis: ::Redis.new(url: REDIS_URL), prefix: prefix)
            per_thread.times do |i|
              store.save_occurrence({
                "fingerprint" => "fp-race",
                "project" => "web",
                "exception_class" => "BoomError",
                "message" => "boom",
                "timestamp" => i.to_f
              })
            end
          end
        end
        workers.each(&:join)

        store = Sentiero::Stores::Redis.new(redis: ::Redis.new(url: REDIS_URL), prefix: prefix)
        problem = store.list_problems(project: nil, limit: 10).first
        assert_equal threads * per_thread, problem[:count].to_i
      ensure
        cleanup_test_keys(::Redis.new(url: REDIS_URL), prefix) if REDIS_AVAILABLE
      end

      def test_different_prefixes_do_not_interfere
        skip "Redis not available" unless REDIS_AVAILABLE

        redis_client = ::Redis.new(url: REDIS_URL)
        prefix_a = "sentiero_prefix_a_test:"
        prefix_b = "sentiero_prefix_b_test:"
        cleanup_test_keys(redis_client, prefix_a)
        cleanup_test_keys(redis_client, prefix_b)

        store_a = Sentiero::Stores::Redis.new(redis: redis_client, prefix: prefix_a)
        store_b = Sentiero::Stores::Redis.new(redis: redis_client, prefix: prefix_b)

        event_a = {"timestamp" => 1.0, "type" => "click", "data" => {"x" => 10}}
        event_b = {"timestamp" => 2.0, "type" => "scroll", "data" => {"y" => 20}}

        store_a.save_events(Sentiero::WindowRef.new("s1", "w1"), [event_a])
        store_b.save_events(Sentiero::WindowRef.new("s1", "w1"), [event_b])

        result_a = store_a.get_events(Sentiero::WindowRef.new("s1", "w1"))
        result_b = store_b.get_events(Sentiero::WindowRef.new("s1", "w1"))

        assert_equal 1, result_a.size
        assert_equal "click", result_a[0]["type"]

        assert_equal 1, result_b.size
        assert_equal "scroll", result_b[0]["type"]

        store_a.delete_session("s1")

        assert_equal [], store_a.get_events(Sentiero::WindowRef.new("s1", "w1"))
        assert_equal 1, store_b.get_events(Sentiero::WindowRef.new("s1", "w1")).size
      ensure
        if redis_client
          cleanup_test_keys(redis_client, prefix_a)
          cleanup_test_keys(redis_client, prefix_b)
        end
      end

      private

      def cleanup_test_keys(redis_client, prefix)
        keys = redis_client.keys("#{prefix}*")
        keys.each { |k| redis_client.del(k) } unless keys.empty?
      end
    end
  end
end
