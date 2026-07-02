# frozen_string_literal: true

require "uri"
require_relative "redaction/config"

module Sentiero
  # Redaction engine for side-channel capture (navigation, form_submit,
  # metadata, error, click) that bypasses rrweb input masking. Must stay
  # byte-for-byte equivalent to the JS twin frontend/src/redaction.js;
  # test/fixtures/redaction_cases.json pins that parity.
  module Redaction
    REDACTED = "[redacted]"

    # Fixed application order, identical to the JS module.
    TEXT_PATTERN_ORDER = %i[url jwt email long_hex card].freeze

    TEXT_PATTERNS = {
      jwt: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/,
      email: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/,
      long_hex: /\b[0-9a-fA-F]{32,}\b/,
      card: /\b\d(?:[ -]?\d){12,18}\b/
    }.freeze

    URL_IN_TEXT = %r{https?://\S+}

    BUILTIN_DENYLIST = %w[
      token access_token refresh_token id_token password passwd pwd secret
      api_key apikey key sig signature code auth session sessionid otp
    ].freeze

    CUSTOM_EVENT_TYPE = 5
    META_EVENT_TYPE = 4

    URL_METADATA_KEYS = %w[url referrer entry_url entry_referrer].freeze

    # tag => { "field" => :url|:text }
    CUSTOM_FIELD_MAP = {
      "navigation" => {"url" => :url, "text" => :text},
      "__form_submit" => {"url" => :url},
      "error" => {"message" => :text, "stack" => :text, "source" => :url},
      "__click" => {"selector" => :text}
    }.freeze

    module_function

    def redact_url(url, config = Config.new)
      return url unless url.is_a?(String)

      case config.url_mode
      when :keep_all then url
      when :keep_filtered then filter_url(url, config)
      else strip_url_string(url)
      end
    end

    def redact_text(value, config = Config.new)
      return value unless value.is_a?(String)

      out = value
      config.active_text_patterns.each do |name|
        out = apply_text_pattern(out, name)
      end
      config.custom_patterns.each { |re| out = out.gsub(re, REDACTED) }
      out
    end

    def redact_event(event, config = Config.new)
      return event unless event.is_a?(Hash)

      if event["type"] == CUSTOM_EVENT_TYPE && event["data"].is_a?(Hash)
        redact_custom_event(event, config)
      elsif event["type"] == META_EVENT_TYPE && event["data"].is_a?(Hash)
        redact_meta_event(event, config)
      else
        redact_dom_event(event, config)
      end
    end

    def redact_metadata(metadata, config = Config.new)
      return metadata unless metadata.is_a?(Hash)

      metadata.to_h do |key, value|
        if URL_METADATA_KEYS.include?(key)
          [key, redact_url(value, config)]
        else
          [key, deep_redact_strings(value, config)]
        end
      end
    end

    def apply_text_pattern(text, name)
      if name == :url
        text.gsub(URL_IN_TEXT) { |m| strip_url_string(m) }
      else
        text.gsub(TEXT_PATTERNS.fetch(name), REDACTED)
      end
    end

    def filter_url(url, config)
      base, query, frag = split_url(url)
      pairs = query.empty? ? [] : query.split("&").filter_map { |p| filter_param(p, config) }
      out = base
      out += "?#{pairs.join("&")}" unless pairs.empty?
      out += "##{redact_text(frag, config)}" unless frag.empty?
      out
    end

    def filter_param(pair, config)
      eq = pair.index("=")
      name = (eq ? pair[0...eq] : pair).downcase
      # Denylist wins over the allowlist so allowlisting a built-in secret name
      # (token/password/...) can't re-enable persisting it.
      return nil if config.effective_denylist.include?(name)
      return pair if config.effective_allowlist.include?(name)
      return pair unless eq

      # Match patterns against the decoded value (email=user%40example.com must
      # be caught the same as email=user@example.com) but only substitute when
      # something actually matched; a clean survivor keeps its original,
      # unmodified encoding rather than being needlessly re-encoded.
      raw_value = pair[(eq + 1)..]
      decoded = url_decode(raw_value)
      redacted = redact_text(decoded, config)
      (redacted == decoded) ? pair : "#{pair[0...eq]}=#{redacted}"
    end

    # Plain percent-decode (leaves "+" alone, unlike www-form decoding). Falls
    # back to the raw value on malformed escapes or invalid UTF-8 rather than
    # raising, since this parses attacker-controlled URLs from public events.
    def url_decode(value)
      decoded = URI::RFC2396_PARSER.unescape(value)
      decoded.valid_encoding? ? decoded : value
    end

    # Manual split (not URI) so JS and Ruby behave identically on edge cases.
    def split_url(url)
      base = url
      frag = ""
      if (h = base.index("#"))
        frag = base[(h + 1)..]
        base = base[0...h]
      end
      query = ""
      if (q = base.index("?"))
        query = base[(q + 1)..]
        base = base[0...q]
      end
      [base, query, frag]
    end

    def strip_url_string(url)
      cut = url.index("?") || url.length
      hash = url.index("#")
      cut = hash if hash && hash < cut
      url[0...cut]
    end

    def redact_custom_event(event, config)
      map = CUSTOM_FIELD_MAP[event["data"]["tag"]]
      payload = event["data"]["payload"]
      return event unless payload.is_a?(Hash)

      # Mapped fields use their url/text treatment; every other field (and every
      # field of an unmapped tag) is deep-redacted rather than stored raw, so a
      # buggy/hostile client can't smuggle PII through an unmapped key.
      new_payload = payload.to_h do |k, v|
        case map&.dig(k)
        when :url then [k, redact_url(v, config)]
        when :text then [k, redact_text(v, config)]
        else [k, deep_redact_strings(v, config)]
        end
      end
      event.merge("data" => event["data"].merge("payload" => new_payload))
    end

    # DOM text/data is left alone unless the operator opts in.
    def redact_dom_event(event, config)
      return event if config.dom_patterns.empty? && config.custom_patterns.empty?
      return event unless event["data"]

      dom_cfg = Config.new(disabled_patterns: TEXT_PATTERN_ORDER - config.dom_patterns,
        custom_patterns: config.custom_patterns)
      event.merge("data" => deep_redact_strings(event["data"], dom_cfg))
    end

    # rrweb Meta events (type 4) carry the full page URL in data.href, which
    # bypasses rrweb's own input masking entirely; always URL-redact it like
    # any other structural URL field (navigation.url, error.source, ...).
    def redact_meta_event(event, config)
      return event unless event["data"].key?("href")

      event.merge("data" => event["data"].merge("href" => redact_url(event["data"]["href"], config)))
    end

    def deep_redact_strings(value, config)
      case value
      when String then redact_text(value, config)
      when Array then value.map { |v| deep_redact_strings(v, config) }
      when Hash
        # Keys can carry PII too (e.g. a caller using an email as a hash key);
        # redact them the same as values. Last-write-wins on key collisions.
        value.to_h { |k, v| [deep_redact_strings(k, config), deep_redact_strings(v, config)] }
      else value
      end
    end
  end
end
