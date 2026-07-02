# frozen_string_literal: true

require "test_helper"
require "sentiero/web/errors_app"
require "sentiero/web/track_app"
require "rack/test"
require "json"

module Sentiero
  module Web
    # Server-side redaction backstop for the error/track ingest lanes, mirroring
    # the recorder lane (events_app). A client that fails to redact — or a
    # non-Sentiero caller — must not get raw PII persisted.
    class IngestRedactionTest < Minitest::Test
      include Rack::Test::Methods

      attr_reader :app

      def setup
        Sentiero.configure do |c|
          c.store = Stores::Memory.new
          c.ingest_keys = {"k1" => "app"}
        end
      end

      def teardown = Sentiero.reset_configuration!

      def auth = {"HTTP_AUTHORIZATION" => "Bearer k1", "CONTENT_TYPE" => "application/json"}

      def test_errors_app_redacts_message_and_backtrace
        @app = ErrorsApp.new
        post "/", JSON.generate(
          "exception_class" => "RuntimeError",
          "message" => "failed for jane@example.com",
          "backtrace" => ["/srv/app.rb:1 jane@example.com"],
          "timestamp" => 1000.0
        ), auth

        fp = JSON.parse(last_response.body)["fingerprint"]
        occ = Sentiero.store.get_occurrences(fp).first
        assert_equal "failed for [redacted]", occ["message"]
        refute_includes occ["backtrace"].join("\n"), "jane@example.com"
      end

      def test_errors_app_redacts_context_values
        @app = ErrorsApp.new
        post "/", JSON.generate(
          "exception_class" => "RuntimeError",
          "message" => "boom",
          "context" => {"user" => "jane@example.com"},
          "timestamp" => 1000.0
        ), auth

        fp = JSON.parse(last_response.body)["fingerprint"]
        occ = Sentiero.store.get_occurrences(fp).first
        assert_equal "[redacted]", occ["context"]["user"]
      end

      def test_track_app_redacts_payload_values
        @app = TrackApp.new
        post "/", JSON.generate(
          "name" => "checkout",
          "payload" => {"note" => "ping jane@example.com"},
          "timestamp" => 1000.0
        ), auth

        ev = Sentiero.store.list_server_events(project: "app", limit: 10).first
        assert_equal "ping [redacted]", ev["payload"]["note"]
      end
    end
  end
end
