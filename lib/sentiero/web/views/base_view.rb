# frozen_string_literal: true

require "erb"
require "concurrent-ruby"
require_relative "../escaping"
require_relative "../formatting"
require_relative "../manifest"

module Sentiero
  module Web
    module Views
      class BaseView
        include Escaping
        include Formatting

        TEMPLATES_DIR = File.expand_path("../templates", __dir__).freeze
        TEMPLATE_CACHE = Concurrent::Map.new

        attr_accessor :base_path, :csrf_token

        def initialize
          @base_path = ""
        end

        def h(text) = escape_html(text)

        def escape_js(text) = escape_js_string(text)

        def built_asset(name) = Sentiero::Web::Manifest.asset_path(name, base_path)

        # Non-empty since/until query params, for range-preserving cross-links.
        # Available to any view exposing since/until_str accessors.
        def range_pairs
          pairs = {}
          pairs["since"] = since if since && !since.to_s.empty?
          pairs["until"] = until_str if until_str && !until_str.to_s.empty?
          pairs
        end

        def template
          raise NotImplementedError, "#{self.class} must define #template"
        end

        def render
          render_with(template, view: self)
        end

        def render_partial(filename, **locals)
          render_with(filename, view: self, **locals)
        end

        def render_session_row(session, selectable, csrf_token = nil)
          render_partial("_session_row.html.erb", s: session, selectable: selectable, csrf_token: csrf_token)
        end

        def render_layout(content, request_path:)
          render_with("dashboard.html.erb", view: self, content: content, request_path: request_path)
        end

        def self.compiled_template(filename)
          TEMPLATE_CACHE.compute_if_absent(filename) do
            ERB.new(File.read(File.join(TEMPLATES_DIR, filename)), trim_mode: "-")
          end
        end

        private

        def render_with(filename, **locals)
          b = binding
          locals.each { |k, v| b.local_variable_set(k, v) }
          self.class.compiled_template(filename).result(b)
        end
      end
    end
  end
end
