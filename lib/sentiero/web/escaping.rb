# frozen_string_literal: true

require "cgi/escape"
require "json"

module Sentiero
  module Web
    # HTML and JavaScript escaping for safe template rendering using only stdlib.
    module Escaping
      # Chars safe in JSON but unsafe in HTML <script>: prevents </script>
      # breakout and HTML entity interpretation (mirrors ERB::Util.json_escape).
      HTML_UNSAFE_IN_SCRIPT = {
        "<" => '\u003c',
        ">" => '\u003e',
        "&" => '\u0026',
        "\u2028" => '\u2028',
        "\u2029" => '\u2029'
      }.freeze

      HTML_UNSAFE_IN_SCRIPT_PATTERN = Regexp.union(HTML_UNSAFE_IN_SCRIPT.keys).freeze

      def escape_html(text)
        CGI.escapeHTML(text.to_s)
      end

      # Escapes for embedding in a JS string literal; returns content WITHOUT surrounding quotes.
      def escape_js_string(text)
        json = JSON.generate(text.to_s)
        json[1..-2].gsub(HTML_UNSAFE_IN_SCRIPT_PATTERN, HTML_UNSAFE_IN_SCRIPT)
      end

      def escape_json(json_string)
        json_string.gsub(HTML_UNSAFE_IN_SCRIPT_PATTERN, HTML_UNSAFE_IN_SCRIPT)
      end
    end
  end
end
