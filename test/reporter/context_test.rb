# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/context"

module Sentiero
  module Reporter
    class ContextTest < Minitest::Test
      def test_construction_normalizes_keys
        ctx = Context.new(:plan => "pro", "region" => "eu")
        assert_equal({"plan" => "pro", "region" => "eu"}, ctx.to_h)
      end

      def test_empty_by_default
        assert Context.new.empty?
        refute Context.new(a: 1).empty?
      end

      def test_lookup_accepts_symbol_or_string
        ctx = Context.new(plan: "pro")
        assert_equal "pro", ctx["plan"]
        assert_equal "pro", ctx[:plan]
      end

      def test_key_accepts_symbol_or_string
        ctx = Context.new(plan: "pro")
        assert ctx.key?("plan")
        assert ctx.key?(:plan)
        refute ctx.key?(:missing)
      end

      def test_merge_returns_new_instance_and_leaves_receiver_unchanged
        base = Context.new(a: 1)
        merged = base.merge(b: 2)

        refute_same base, merged
        assert_equal({"a" => 1}, base.to_h)
        assert_equal({"a" => 1, "b" => 2}, merged.to_h)
      end

      def test_merge_normalizes_incoming_keys
        merged = Context.new("a" => 1).merge(b: 2)
        assert_equal({"a" => 1, "b" => 2}, merged.to_h)
      end

      def test_merge_overrides_existing_keys
        merged = Context.new(plan: "free").merge(plan: "pro")
        assert_equal "pro", merged["plan"]
      end

      def test_merge_accepts_another_context
        merged = Context.new(a: 1).merge(Context.new(b: 2))
        assert_equal({"a" => 1, "b" => 2}, merged.to_h)
      end

      def test_merge_with_non_hash_is_a_no_op
        merged = Context.new(a: 1).merge(nil)
        assert_equal({"a" => 1}, merged.to_h)
      end

      def test_to_h_returns_a_copy
        ctx = Context.new(a: 1)
        copy = ctx.to_h
        copy["a"] = "mutated"
        assert_equal({"a" => 1}, ctx.to_h)
      end
    end
  end
end
