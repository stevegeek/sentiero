# frozen_string_literal: true

require "test_helper"
require "sentiero/web/track_app"
require "rack/test"
require "json"

module Sentiero
  module Web
    class TrackAppTest < Minitest::Test
      include Rack::Test::Methods

      def app = TrackApp.new

      def setup
        Sentiero.configure do |c|
          c.store = Stores::Memory.new
          c.ingest_keys = {"k1" => "app"}
        end
      end

      def teardown = Sentiero.reset_configuration!

      def auth = {"HTTP_AUTHORIZATION" => "Bearer k1", "CONTENT_TYPE" => "application/json"}

      def test_valid_post_stores_server_event
        post "/", JSON.generate({"name" => "signup", "level" => "info", "payload" => {"plan" => "pro"},
                                 "session_id" => "sess_1", "timestamp" => 1000.0}), auth
        assert_equal 200, last_response.status
        ev = Sentiero.store.list_server_events(project: "app", limit: 10).first
        assert_equal "signup", ev["name"]
        assert_equal "info", ev["level"]
        assert_equal "sess_1", ev["session_id"]
      end

      def test_missing_name_is_400
        post "/", JSON.generate({"level" => "info"}), auth
        assert_equal 400, last_response.status
      end

      def test_missing_timestamp_defaults_to_now
        post "/", JSON.generate({"name" => "x"}), auth
        assert_equal 200, last_response.status
        assert_operator Sentiero.store.list_server_events(project: "app", limit: 10).first["timestamp"], :>, 0
      end

      def test_unknown_level_coerced_to_info
        post "/", JSON.generate({"name" => "x", "level" => "banana", "timestamp" => 1.0}), auth
        assert_equal "info", Sentiero.store.list_server_events(project: "app", limit: 10).first["level"]
      end

      def test_invalid_session_id_is_400
        post "/", JSON.generate({"name" => "x", "session_id" => "bad id!"}), auth
        assert_equal 400, last_response.status
      end

      def test_bad_key_is_401
        post "/", JSON.generate({"name" => "x"}), {"HTTP_AUTHORIZATION" => "Bearer nope", "CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
      end

      def test_bad_key_stores_nothing
        post "/", JSON.generate({"name" => "x"}), {"HTTP_AUTHORIZATION" => "Bearer nope", "CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
        assert_equal [], Sentiero.store.list_server_events(project: "app", limit: 10)
      end
    end
  end
end
