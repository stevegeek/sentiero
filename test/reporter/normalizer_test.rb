# frozen_string_literal: true

require "test_helper"
require "sentiero/reporter/normalizer"

module Sentiero
  module Reporter
    class NormalizerTest < Minitest::Test
      def stringify(hash) = Normalizer.stringify_shallow(hash)

      def test_symbol_keys_become_strings
        assert_equal({"plan" => "pro"}, stringify(plan: "pro"))
      end

      def test_string_keys_are_left_as_is
        assert_equal({"region" => "eu"}, stringify("region" => "eu"))
      end

      def test_mixed_keys
        assert_equal({"a" => 1, "b" => 2}, stringify(:a => 1, "b" => 2))
      end

      def test_values_pass_through_unchanged
        nested = {deep: "value"}
        assert_same nested, stringify(outer: nested)["outer"]
      end

      def test_only_top_level_keys_are_stringified
        # Shallow: nested hash keys are untouched.
        assert_equal({"outer" => {inner: 1}}, stringify(outer: {inner: 1}))
      end

      def test_empty_hash
        assert_equal({}, stringify({}))
      end

      def test_non_hash_returns_empty_hash
        assert_equal({}, stringify(nil))
        assert_equal({}, stringify("string"))
        assert_equal({}, stringify([1, 2]))
      end
    end
  end
end
