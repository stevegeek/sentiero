# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/http_transport"
require "socket"

module Sentiero
  module Reporter
    class HttpTransportTest < Minitest::Test
      def test_post_round_trip_sends_json_with_bearer_auth
        response, request = with_one_shot_server do |port|
          transport(port).post("errors", {"exception_class" => "RuntimeError"})
        end
        assert_kind_of Net::HTTPSuccess, response
        assert_equal "200", response.code

        request_line, headers, body = parse_request(request)
        assert_equal "POST /errors HTTP/1.1", request_line
        assert_equal "Bearer secret-key", headers["authorization"]
        assert_equal "application/json", headers["content-type"]
        assert_equal({"exception_class" => "RuntimeError"}, JSON.parse(body))
      end

      def test_trailing_slashes_on_endpoint_are_stripped
        _response, request = with_one_shot_server do |port|
          transport(port, suffix: "///").post("errors", {})
        end
        request_line, = parse_request(request)
        assert_equal "POST /errors HTTP/1.1", request_line
      end

      def test_non_2xx_response_is_returned_without_raising
        response, _request = with_one_shot_server(status_line: "HTTP/1.1 401 Unauthorized") do |port|
          transport(port).post("errors", {})
        end
        assert_kind_of Net::HTTPUnauthorized, response
        assert_equal "401", response.code
      end

      def test_redirect_is_returned_not_followed
        # Location points at a dead port: following it would raise. Pins that
        # the transport makes exactly one request and hands back the 302.
        response, _request = with_one_shot_server(
          status_line: "HTTP/1.1 302 Found",
          extra_headers: {"location" => "http://127.0.0.1:1/errors"}
        ) do |port|
          transport(port).post("errors", {})
        end
        assert_kind_of Net::HTTPRedirection, response
        assert_equal "302", response.code
      end

      def test_unresponsive_server_raises_read_timeout
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        # The listen backlog completes the TCP handshake, but nothing ever
        # reads or replies — the bounded read_timeout must fire.
        t = HttpTransport.new(endpoint: "http://127.0.0.1:#{port}", ingest_key: "k",
          open_timeout: 1, read_timeout: 0.1)
        assert_raises(Net::ReadTimeout) { t.post("errors", {}) }
      ensure
        server&.close
      end

      def test_connection_refused_raises
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        server.close # nothing listens here any more
        assert_raises(Errno::ECONNREFUSED) { transport(port).post("errors", {}) }
      end

      def test_build_http_enables_tls_for_https
        t = HttpTransport.new(endpoint: "https://collector.example", ingest_key: "k",
          open_timeout: 2, read_timeout: 3)
        http = t.send(:build_http, URI.parse("https://collector.example/errors"))
        assert_predicate http, :use_ssl?
        assert_equal 2, http.open_timeout
        assert_equal 3, http.read_timeout
      end

      def test_build_http_stays_plain_for_http
        t = HttpTransport.new(endpoint: "http://collector.example", ingest_key: "k",
          open_timeout: 2, read_timeout: 3)
        http = t.send(:build_http, URI.parse("http://collector.example/errors"))
        refute_predicate http, :use_ssl?
        assert_equal 2, http.open_timeout
        assert_equal 3, http.read_timeout
      end

      def test_warns_when_non_loopback_endpoint_uses_http
        _out, err = capture_io do
          HttpTransport.new(endpoint: "http://collector.example", ingest_key: "k",
            open_timeout: 1, read_timeout: 1)
        end
        assert_match(/http:\/\/.*unencrypted/i, err)
      end

      def test_does_not_warn_for_https_or_loopback
        _out, err = capture_io do
          HttpTransport.new(endpoint: "https://collector.example", ingest_key: "k", open_timeout: 1, read_timeout: 1)
          HttpTransport.new(endpoint: "http://localhost:9000", ingest_key: "k", open_timeout: 1, read_timeout: 1)
          HttpTransport.new(endpoint: "http://127.0.0.1:9000", ingest_key: "k", open_timeout: 1, read_timeout: 1)
        end
        assert_empty err
      end

      private

      def transport(port, suffix: "")
        HttpTransport.new(endpoint: "http://127.0.0.1:#{port}#{suffix}", ingest_key: "secret-key",
          open_timeout: 2, read_timeout: 2)
      end

      # Boots a one-shot HTTP stub on a random loopback port: accepts a single
      # connection, captures the raw request, replies with a canned response.
      # Returns [block_result, raw_request]. Stdlib-only — no new dependencies.
      def with_one_shot_server(status_line: "HTTP/1.1 200 OK", body: "ok", extra_headers: {})
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        thread = Thread.new do
          socket = server.accept
          request = read_http_request(socket)
          headers = extra_headers.merge("content-length" => body.bytesize, "connection" => "close")
          header_block = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
          socket.write("#{status_line}\r\n#{header_block}\r\n#{body}")
          socket.close
          request
        end
        result = yield port
        [result, thread.value]
      ensure
        server&.close
        thread&.kill
      end

      def read_http_request(socket)
        request = +""
        request << socket.readline until request.end_with?("\r\n\r\n")
        if (length = request[/^content-length:\s*(\d+)/i, 1])
          request << socket.read(length.to_i)
        end
        request
      end

      def parse_request(raw)
        head, body = raw.split("\r\n\r\n", 2)
        request_line, *header_lines = head.split("\r\n")
        headers = header_lines.to_h do |line|
          key, value = line.split(":", 2)
          [key.downcase, value.strip]
        end
        [request_line, headers, body]
      end
    end
  end
end
