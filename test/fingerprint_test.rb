# frozen_string_literal: true

require "test_helper"
require "sentiero/fingerprint"
require "timeout"

class FingerprintTest < Minitest::Test
  def test_is_deterministic
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `f'"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `f'"], project: "app")
    assert_equal a, b
  end

  def test_line_numbers_do_not_affect_grouping
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `f'"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:99:in `f'"], project: "app")
    assert_equal a, b
  end

  def test_numbered_method_names_stay_distinct
    # Digits inside an identifier are part of the method name, not a line
    # number, so two differently-numbered methods must not group together.
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `Object#step_1'"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `Object#step_2'"], project: "app")
    refute_equal a, b
  end

  def test_numbered_namespaces_stay_distinct
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `V1::Api#call'"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `V2::Api#call'"], project: "app")
    refute_equal a, b
  end

  def test_different_class_changes_fingerprint
    a = Sentiero::Fingerprint.compute(exception_class: "A", backtrace: ["app/x.rb:14"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "B", backtrace: ["app/x.rb:14"], project: "app")
    refute_equal a, b
  end

  def test_different_project_changes_fingerprint
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "p1")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "p2")
    refute_equal a, b
  end

  def test_memory_addresses_normalized
    a = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["#<Obj:0x00007fa1b2>"], project: "app")
    b = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["#<Obj:0x00009999c1>"], project: "app")
    assert_equal a, b
  end

  def test_result_matches_valid_id_format
    fp = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["x"], project: "app")
    assert_match(/\A[a-zA-Z0-9_-]{1,128}\z/, fp)
  end

  def test_nil_and_empty_backtrace_are_safe
    assert Sentiero::Fingerprint.compute(exception_class: "E", backtrace: nil, project: "app")
    assert Sentiero::Fingerprint.compute(exception_class: "E", backtrace: [], project: "app")
  end

  def test_normalization_is_linear_time_on_pathological_input
    # A long digit/hex run must not cause catastrophic backtracking.
    evil = "a" + ("1234567890abcdef" * 5000)
    Timeout.timeout(2) do
      Sentiero::Fingerprint.compute(exception_class: "E", backtrace: [evil], project: "app")
    end
  end
end
