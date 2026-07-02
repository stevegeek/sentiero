# frozen_string_literal: true

require "test_helper"
require "sentiero/web/escaping"

class EscapingTest < Minitest::Test
  include Sentiero::Web::Escaping

  # ── escape_html ──

  def test_escape_html_escapes_angle_brackets
    assert_equal "&lt;script&gt;", escape_html("<script>")
  end

  def test_escape_html_escapes_ampersand
    assert_equal "a &amp; b", escape_html("a & b")
  end

  def test_escape_html_escapes_quotes
    assert_equal "&quot;hello&quot;", escape_html('"hello"')
  end

  def test_escape_html_passes_safe_text_through
    assert_equal "hello world", escape_html("hello world")
  end

  def test_escape_html_coerces_non_string
    assert_equal "42", escape_html(42)
  end

  # ── escape_js_string ──

  def test_escape_js_string_escapes_backslash
    assert_includes escape_js_string('a\\b'), "\\\\"
  end

  def test_escape_js_string_escapes_double_quote
    assert_includes escape_js_string('say "hi"'), '\\"'
  end

  def test_escape_js_string_escapes_newlines
    result = escape_js_string("line1\nline2")
    assert_includes result, '\\n'
  end

  def test_escape_js_string_escapes_carriage_return
    result = escape_js_string("a\rb")
    assert_includes result, '\\r'
  end

  def test_escape_js_string_escapes_script_close_tag
    result = escape_js_string("</script>")
    refute_includes result, "</script>"
    assert_includes result, '\\u003c'
  end

  def test_escape_js_string_escapes_angle_brackets
    result = escape_js_string("<div>test</div>")
    refute_includes result, "<"
    refute_includes result, ">"
  end

  def test_escape_js_string_escapes_ampersand
    result = escape_js_string("a & b")
    refute_includes result, "&"
    assert_includes result, '\\u0026'
  end

  def test_escape_js_string_escapes_line_separator
    result = escape_js_string("a\u2028b")
    refute_includes result, "\u2028"
  end

  def test_escape_js_string_escapes_paragraph_separator
    result = escape_js_string("a\u2029b")
    refute_includes result, "\u2029"
  end

  def test_escape_js_string_returns_without_surrounding_quotes
    result = escape_js_string("hello")
    refute result.start_with?('"')
    refute result.end_with?('"')
    assert_equal "hello", result
  end

  # ── escape_json ──

  def test_escape_json_escapes_script_close_tag
    json = '{"html":"</script>"}'
    result = escape_json(json)
    refute_includes result, "</script>"
    assert_includes result, '\\u003c'
  end

  def test_escape_json_preserves_valid_json_structure
    json = '{"key":"value","num":42}'
    result = escape_json(json)
    assert_equal json, result
  end

  def test_escape_json_escapes_ampersand
    json = '{"q":"a & b"}'
    result = escape_json(json)
    refute_includes result, "&"
    assert_includes result, '\\u0026'
  end

  def test_escape_json_escapes_line_separators
    json = "{\"text\":\"a\u2028b\u2029c\"}"
    result = escape_json(json)
    refute_includes result, "\u2028"
    refute_includes result, "\u2029"
  end

  def test_escape_json_roundtrips_through_browser_json_parse
    # The escaped output should still be parseable as JSON
    original = '{"url":"https://example.com?a=1&b=2"}'
    escaped = escape_json(original)
    # Replace unicode escapes back to verify structure
    unescaped = escaped.gsub('\\u0026', "&").gsub('\\u003c', "<").gsub('\\u003e', ">")
    parsed = JSON.parse(unescaped)
    assert_equal "https://example.com?a=1&b=2", parsed["url"]
  end
end
