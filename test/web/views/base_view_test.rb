# frozen_string_literal: true

require "test_helper"
require "sentiero/web/views/base_view"

class BaseViewTest < Minitest::Test
  class DummyView < Sentiero::Web::Views::BaseView
    def template = "_truncation_warning.html.erb"
  end

  def setup
    @view = DummyView.new
    @view.base_path = "/mnt"
  end

  def test_h_escapes_html
    assert_equal "a&lt;b", @view.h("a<b")
  end

  def test_format_duration_available_via_module
    assert_equal "5s", @view.format_duration(0, 5000)
  end

  def test_template_is_abstract
    assert_raises(NotImplementedError) { Sentiero::Web::Views::BaseView.new.render }
  end

  def test_render_partial_renders_with_locals
    html = @view.render_partial("_truncation_warning.html.erb", was_truncated: true, noun: "things")
    assert_includes html, "things may not be reflected"
  end
end
