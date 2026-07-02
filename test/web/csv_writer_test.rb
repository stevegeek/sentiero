# frozen_string_literal: true

require "test_helper"
require "sentiero/web/csv_writer"

class CsvWriterTest < Minitest::Test
  CsvWriter = Sentiero::Web::CsvWriter

  # ── stringify ──

  def test_stringify_nil
    assert_equal "", CsvWriter.stringify(nil)
  end

  def test_stringify_booleans
    assert_equal "true", CsvWriter.stringify(true)
    assert_equal "false", CsvWriter.stringify(false)
  end

  def test_stringify_other
    assert_equal "42", CsvWriter.stringify(42)
    assert_equal "hello", CsvWriter.stringify("hello")
  end

  # ── guard_injection ──

  def test_guard_injection_empty_string
    assert_equal "", CsvWriter.guard_injection("")
  end

  def test_guard_injection_formula_triggers
    assert_equal "'=SUM(A1)", CsvWriter.guard_injection("=SUM(A1)")
    assert_equal "'+1", CsvWriter.guard_injection("+1")
    assert_equal "'-1", CsvWriter.guard_injection("-1")
    assert_equal "'@cmd", CsvWriter.guard_injection("@cmd")
  end

  def test_guard_injection_normal_cell
    assert_equal "hello", CsvWriter.guard_injection("hello")
  end

  # ── quote ──

  def test_quote_passes_through_simple_value
    assert_equal "hello", CsvWriter.quote("hello")
  end

  def test_quote_wraps_value_with_comma
    assert_equal %("a,b"), CsvWriter.quote("a,b")
  end

  def test_quote_doubles_embedded_quotes
    assert_equal %("a""b"), CsvWriter.quote(%(a"b))
  end
end
