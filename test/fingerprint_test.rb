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

  def test_default_normalizer_matches_explicit_ruby_normalizer
    default = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `f'"], project: "app")
    explicit = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14:in `f'"], project: "app", normalizer: Sentiero::Fingerprint::RUBY_NORMALIZER)
    assert_equal explicit, default
  end

  def test_ruby_normalizer_collapses_line_numbers
    a = Sentiero::Fingerprint::RUBY_NORMALIZER.call("app.rb:42:in 'm'")
    b = Sentiero::Fingerprint::RUBY_NORMALIZER.call("app.rb:9:in 'm'")
    assert_equal a, b
  end

  def test_crystal_normalizer_collapses_line_and_line_col_forms
    a = Sentiero::Fingerprint::CRYSTAL_NORMALIZER.call("src/app.cr:451 in 'a'")
    b = Sentiero::Fingerprint::CRYSTAL_NORMALIZER.call("src/app.cr:5:3 in 'a'")
    assert_equal a, b
  end

  def test_crystal_normalizer_differs_from_ruby_normalizer_on_same_input
    frame = "src/app.cr:451 in 'a'"
    refute_equal Sentiero::Fingerprint::RUBY_NORMALIZER.call(frame), Sentiero::Fingerprint::CRYSTAL_NORMALIZER.call(frame)
  end

  def test_generic_normalizer_strips_trailing_line_and_line_col_only
    assert_equal "app.py:N", Sentiero::Fingerprint::GENERIC_NORMALIZER.call("app.py:42")
    assert_equal "app.py:N", Sentiero::Fingerprint::GENERIC_NORMALIZER.call("app.py:42:7")
    # Coarse by design: no `in`-token assumption, so it cannot see line noise
    # that isn't at the end of the frame.
    assert_equal "app.rb:42:in 'm'", Sentiero::Fingerprint::GENERIC_NORMALIZER.call("app.rb:42:in 'm'")
  end

  def test_all_builtin_normalizers_strip_memory_addresses
    [Sentiero::Fingerprint::RUBY_NORMALIZER, Sentiero::Fingerprint::CRYSTAL_NORMALIZER, Sentiero::Fingerprint::GENERIC_NORMALIZER].each do |normalizer|
      assert_equal "#<Obj:0xHEX>", normalizer.call("#<Obj:0x00007fa1b2>")
    end
  end

  def test_compute_accepts_custom_normalizer
    upcasing = ->(frame) { frame.upcase }
    fp = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "app", normalizer: upcasing)
    expected = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["APP/X.RB:14"], project: "app", normalizer: upcasing)
    assert_equal expected, fp
  end

  def test_compute_falls_back_to_raw_capped_frame_when_normalizer_raises
    raising = ->(_frame) { raise "boom" }
    with_raise = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "app", normalizer: raising)
    identity = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "app", normalizer: ->(f) { f })
    assert_equal identity, with_raise
  end

  def test_compute_coerces_non_string_normalizer_result
    to_int = ->(_frame) { 12345 }
    fp = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "app", normalizer: to_int)
    expected = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["app/x.rb:14"], project: "app", normalizer: ->(_f) { "12345" })
    assert_equal expected, fp
  end

  def test_compute_re_truncates_and_caps_oversized_normalizer_result
    exploding = ->(_frame) { "x" * (Sentiero::Fingerprint::MAX_FRAME_LENGTH * 2) }
    fp = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["short"], project: "app", normalizer: exploding)
    expected = Sentiero::Fingerprint.compute(exception_class: "E", backtrace: ["short"], project: "app", normalizer: ->(_f) { "x" * Sentiero::Fingerprint::MAX_FRAME_LENGTH })
    assert_equal expected, fp
  end
end
