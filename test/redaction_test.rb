# frozen_string_literal: true

require_relative "test_helper"
require "sentiero/redaction"

class RedactionTextTest < Minitest::Test
  R = Sentiero::Redaction

  def test_email_redacted
    assert_equal "User [redacted] not found",
      R.redact_text("User alice@example.com not found")
  end

  def test_url_in_text_keeps_path_drops_query
    assert_equal "went to https://x.test/p next",
      R.redact_text("went to https://x.test/p?token=abc#frag next")
  end

  def test_non_string_passthrough
    assert_equal 42, R.redact_text(42)
  end

  def test_disabled_pattern
    cfg = R::Config.new(disabled_patterns: [:card])
    assert_equal "card 4111 1111 1111 1111 ok",
      R.redact_text("card 4111 1111 1111 1111 ok", cfg)
  end

  def test_custom_pattern
    cfg = R::Config.new(custom_patterns: [/ACCT-\d{6}/])
    assert_equal "ref [redacted] end", R.redact_text("ref ACCT-123456 end", cfg)
  end
end

class RedactionUrlTest < Minitest::Test
  R = Sentiero::Redaction

  def test_strip_default
    assert_equal "https://x.test/search",
      R.redact_url("https://x.test/search?q=secret#sec")
  end

  def test_keep_all
    cfg = R::Config.new(url_mode: :keep_all)
    assert_equal "https://x.test/p?q=secret#f",
      R.redact_url("https://x.test/p?q=secret#f", cfg)
  end

  def test_keep_filtered
    cfg = R::Config.new(url_mode: :keep_filtered,
      url_param_allowlist: ["utm_source"], url_param_denylist: ["token"])
    assert_equal "https://x.test/p?utm_source=google&email=[redacted]",
      R.redact_url("https://x.test/p?utm_source=google&token=abc&email=a@b.co", cfg)
  end

  def test_keep_filtered_fragment_redacted
    cfg = R::Config.new(url_mode: :keep_filtered)
    assert_equal "https://x.test/p#[redacted]",
      R.redact_url("https://x.test/p#alice@b.co", cfg)
  end
end

require "json"

class RedactionConfigTest < Minitest::Test
  R = Sentiero::Redaction

  def test_to_client_hash_round_trip
    cfg = R::Config.new(url_mode: :keep_filtered, url_param_allowlist: ["Utm_Source"],
      disabled_patterns: [:card], custom_patterns: [/ACCT-\d{6}/])
    h = cfg.to_client_hash
    assert_equal "keepFiltered", h[:urlMode]
    assert_includes h[:urlParamDenylist], "token"
    assert_equal ["card"], h[:disabledPatterns]
    assert_equal ["ACCT-\\d{6}"], h[:customPatterns]
    # from_client_hash reproduces behavior
    rebuilt = R::Config.from_client_hash(JSON.parse(JSON.generate(h)))
    assert_equal "ref [redacted] x", R.redact_text("ref ACCT-123456 x", rebuilt)
  end

  def test_redact_event_navigation
    event = {"type" => 5, "data" => {"tag" => "navigation",
                                     "payload" => {"url" => "https://x.test/p?token=abc", "text" => "a@b.co"}}}
    out = R.redact_event(event)
    assert_equal "https://x.test/p", out["data"]["payload"]["url"]
    assert_equal "[redacted]", out["data"]["payload"]["text"]
  end

  def test_redact_event_dom_untouched_by_default
    event = {"type" => 3, "data" => {"text" => "0123456789abcdef0123456789abcdef"}}
    assert_equal event, R.redact_event(event)
  end

  def test_redact_event_dom_optin
    cfg = R::Config.new(dom_patterns: [:long_hex])
    event = {"type" => 3, "data" => {"text" => "0123456789abcdef0123456789abcdef"}}
    assert_equal "[redacted]", R.redact_event(event, cfg)["data"]["text"]
  end

  # Regression: dom_patterns given as strings must still activate (they were
  # compared against a symbol array, silently no-opping DOM redaction).
  def test_redact_event_dom_optin_accepts_string_pattern_names
    cfg = R::Config.new(dom_patterns: ["long_hex"])
    event = {"type" => 3, "data" => {"text" => "0123456789abcdef0123456789abcdef"}}
    assert_equal "[redacted]", R.redact_event(event, cfg)["data"]["text"]
  end

  # Regression: an unmapped custom-event tag is deep-redacted server-side, not
  # stored raw (defense-in-depth for a buggy/hostile client on the public lane).
  def test_redact_event_unmapped_tag_deep_redacts_payload
    event = {"type" => 5, "data" => {"tag" => "whatever", "payload" => {"email" => "a@b.co", "n" => 3}}}
    payload = R.redact_event(event)["data"]["payload"]
    assert_equal "[redacted]", payload["email"]
    assert_equal 3, payload["n"]
  end

  def test_redact_event_error_redacts_source_url
    event = {"type" => 5, "data" => {"tag" => "error",
                                     "payload" => {"message" => "boom a@b.co",
                                                   "stack" => "at https://x.test/s?k=1",
                                                   "source" => "https://x.test/app.js?token=abc",
                                                   "lineno" => 5}}}
    out = R.redact_event(event)
    payload = out["data"]["payload"]
    assert_equal "https://x.test/app.js", payload["source"]
    assert_equal "boom [redacted]", payload["message"]
    assert_equal "at https://x.test/s", payload["stack"]
    assert_equal 5, payload["lineno"]
  end

  def test_redact_metadata
    md = {"url" => "https://x.test/p?token=abc", "userAgent" => "UA"}
    out = R.redact_metadata(md)
    assert_equal "https://x.test/p", out["url"]
    assert_equal "UA", out["userAgent"]
  end

  # Regression: rrweb Meta events (type 4) carry the full page URL in
  # data.href, unshielded by rrweb's own input masking; it must be
  # URL-redacted like any other structural URL field.
  def test_redact_event_meta_href_stripped_by_default
    event = {"type" => 4, "data" => {"href" => "https://x.test/reset?token=s&email=u@e.com", "width" => 800, "height" => 600}}
    out = R.redact_event(event)
    assert_equal "https://x.test/reset", out["data"]["href"]
    assert_equal 800, out["data"]["width"]
    assert_equal 600, out["data"]["height"]
  end

  def test_redact_event_meta_href_keep_filtered
    cfg = R::Config.new(url_mode: :keep_filtered, url_param_denylist: ["token"])
    event = {"type" => 4, "data" => {"href" => "https://x.test/reset?token=s&email=u@e.com"}}
    out = R.redact_event(event, cfg)
    assert_equal "https://x.test/reset?email=[redacted]", out["data"]["href"]
  end

  def test_redact_event_non_meta_non_custom_untouched
    event = {"type" => 2, "data" => {"href" => "https://x.test/reset?token=s"}}
    assert_equal event, R.redact_event(event)
  end
end

class RedactionCorpusTest < Minitest::Test
  R = Sentiero::Redaction
  CASES = JSON.parse(File.read(File.expand_path("fixtures/redaction_cases.json", __dir__)))

  CASES.each do |c|
    define_method("test_corpus_#{c["name"].gsub(/\W+/, "_")}") do
      cfg = R::Config.from_client_hash(c["config"])
      actual = case c["op"]
      when "url" then R.redact_url(c["input"], cfg)
      when "custom_event" then R.redact_event(c["input"], cfg)
      when "metadata" then R.redact_metadata(c["input"], cfg)
      else R.redact_text(c["input"], cfg)
      end
      assert_equal c["expected"], actual, c["name"]
    end
  end
end

class RedactionCorpusCoverageTest < Minitest::Test
  CASES = JSON.parse(File.read(File.expand_path("fixtures/redaction_cases.json", __dir__)))

  def test_covers_all_url_modes
    modes = CASES.select { |c| c["op"] == "url" }.map { |c| c.dig("config", "urlMode") || "strip" }.uniq
    %w[strip keepAll keepFiltered].each { |m| assert_includes modes, m, "corpus missing url mode #{m}" }
  end

  def test_covers_all_text_patterns
    text = CASES.select { |c| c["op"] == "text" }.map { |c| c["name"] }.join(" ")
    %w[email jwt hex card url].each { |p| assert_includes text, p, "corpus missing #{p} text case" }
  end
end
