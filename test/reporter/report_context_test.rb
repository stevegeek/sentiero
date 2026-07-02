# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/context"
require "sentiero/reporter/report_context"

module Sentiero
  module Reporter
    class ReportContextTest < Minitest::Test
      def build(hash) = ReportContext.new(Context.new(hash))

      def test_extracts_reserved_keys
        rc = build(session_id: "sess_1", window_id: "win_1")
        assert_equal "sess_1", rc.session_id
        assert_equal "win_1", rc.window_id
      end

      def test_metadata_excludes_reserved_keys
        rc = build(session_id: "sess_1", window_id: "win_1", account: "acme")
        assert_equal({"account" => "acme"}, rc.metadata)
      end

      def test_absent_reserved_keys_are_nil
        rc = build(account: "acme")
        assert_nil rc.session_id
        assert_nil rc.window_id
      end

      def test_non_reserved_keys_preserved
        rc = build(account: "acme", region: "eu")
        assert_equal({"account" => "acme", "region" => "eu"}, rc.metadata)
      end

      def test_metadata_is_mutable_for_injection
        rc = build(account: "acme")
        rc.metadata["environment"] = "test"
        assert_equal({"account" => "acme", "environment" => "test"}, rc.metadata)
      end

      def test_does_not_mutate_source_context
        ctx = Context.new(session_id: "sess_1", account: "acme")
        ReportContext.new(ctx)
        assert_equal({"session_id" => "sess_1", "account" => "acme"}, ctx.to_h)
      end
    end
  end
end
