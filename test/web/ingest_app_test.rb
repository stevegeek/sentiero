# frozen_string_literal: true

require "test_helper"
require "sentiero/web/ingest_app"
require "rack/test"
require "json"

module Sentiero
  module Web
    class IngestAppTest < Minitest::Test
      include Rack::Test::Methods

      # Minimal concrete subclass that echoes the resolved project + parsed body.
      class Echo < IngestApp
        def handle(env, project, data)
          json_response(200, {project: project, got: data})
        end
      end

      def app = Echo.new

      def setup
        Sentiero.configure do |c|
          c.store = Stores::Memory.new
          c.ingest_keys = {"secret-key" => "myapp"}
        end
      end

      def teardown = Sentiero.reset_configuration!

      def auth = {"HTTP_AUTHORIZATION" => "Bearer secret-key", "CONTENT_TYPE" => "application/json"}

      def test_valid_key_resolves_project_and_parses_body
        post "/", JSON.generate({"hello" => "world"}), auth
        assert_equal 200, last_response.status
        body = JSON.parse(last_response.body)
        assert_equal "myapp", body["project"]
        assert_equal({"hello" => "world"}, body["got"])
      end

      def test_missing_authorization_is_401
        post "/", JSON.generate({}), {"CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
      end

      def test_unknown_key_is_401
        post "/", JSON.generate({}), {"HTTP_AUTHORIZATION" => "Bearer nope", "CONTENT_TYPE" => "application/json"}
        assert_equal 401, last_response.status
      end

      def test_no_keys_configured_rejects_all
        Sentiero.configuration.ingest_keys = {}
        post "/", JSON.generate({}), auth
        assert_equal 401, last_response.status
      end

      def test_invalid_json_is_400
        post "/", "{not json", auth
        assert_equal 400, last_response.status
      end

      def test_oversized_body_is_413
        big = "x" * (BodyReader::MAX_BODY_SIZE + 10)
        post "/", JSON.generate({"data" => big}), auth
        assert_equal 413, last_response.status
      end

      def test_non_post_is_405
        get "/", {}, auth
        assert_equal 405, last_response.status
      end

      def test_gzip_body_is_decoded
        require "zlib"
        require "stringio"
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io)
        gz.write(JSON.generate({"z" => 1}))
        gz.close
        post "/", io.string, auth.merge("HTTP_CONTENT_ENCODING" => "gzip")
        assert_equal 200, last_response.status
        assert_equal({"z" => 1}, JSON.parse(last_response.body)["got"])
      end

      def test_invalid_gzip_is_400
        post "/", "not actually gzip", auth.merge("HTTP_CONTENT_ENCODING" => "gzip")
        assert_equal 400, last_response.status
      end

      def test_gzip_that_inflates_past_limit_is_413
        require "zlib"
        require "stringio"
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io)
        gz.write("x" * (BodyReader::MAX_BODY_SIZE + 100))
        gz.close
        post "/", io.string, auth.merge("HTTP_CONTENT_ENCODING" => "gzip")
        assert_equal 413, last_response.status
      end
    end
  end
end
