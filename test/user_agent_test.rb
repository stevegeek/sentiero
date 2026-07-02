# frozen_string_literal: true

require "test_helper"

# Coarse UA classification. The strings below are real, recent (2024-2025)
# User-Agent values for representative browser/OS combinations. Tests assert the
# bucket each falls into and pin down the known limitations of regex-based
# coarse bucketing (e.g. Android tablets that omit "Tablet" read as Mobile).
class UserAgentTest < Minitest::Test
  def device(ua) = Sentiero::UserAgent.device(ua)

  def browser(ua) = Sentiero::UserAgent.browser(ua)

  CHROME_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  CHROME_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  FIREFOX_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
  SAFARI_MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15"
  EDGE_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
  OPERA_WIN = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 OPR/106.0.0.0"

  CHROME_ANDROID = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
  SAFARI_IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1"
  FIREFOX_ANDROID = "Mozilla/5.0 (Android 13; Mobile; rv:121.0) Gecko/121.0 Firefox/121.0"
  SAMSUNG_ANDROID = "Mozilla/5.0 (Linux; Android 13; SAMSUNG SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/23.0 Chrome/115.0.0.0 Mobile Safari/537.36"

  IPAD_MOBILE_UA = "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
  IPAD_DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
  ANDROID_TABLET_FIREFOX = "Mozilla/5.0 (Android 13; Tablet; rv:121.0) Gecko/121.0 Firefox/121.0"
  ANDROID_TABLET_CHROME = "Mozilla/5.0 (Linux; Android 13; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  GOOGLEBOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  CURL = "curl/8.4.0"

  # --- device ---------------------------------------------------------------

  def test_desktop_browsers_are_desktop
    assert_equal "Desktop", device(CHROME_WIN)
    assert_equal "Desktop", device(CHROME_MAC)
    assert_equal "Desktop", device(FIREFOX_WIN)
    assert_equal "Desktop", device(SAFARI_MAC)
    assert_equal "Desktop", device(EDGE_WIN)
    assert_equal "Desktop", device(OPERA_WIN)
  end

  def test_phones_are_mobile
    assert_equal "Mobile", device(CHROME_ANDROID)
    assert_equal "Mobile", device(SAFARI_IPHONE)
    assert_equal "Mobile", device(FIREFOX_ANDROID)
    assert_equal "Mobile", device(SAMSUNG_ANDROID)
  end

  # iPad is matched on the "iPad" token before the Mobile rule, so iPads that
  # still carry "Mobile" in their UA bucket as Tablet, not Mobile.
  def test_ipad_with_mobile_token_is_tablet
    assert_equal "Tablet", device(IPAD_MOBILE_UA)
  end

  # An Android tablet that announces "Tablet" buckets correctly...
  def test_android_tablet_with_tablet_token_is_tablet
    assert_equal "Tablet", device(ANDROID_TABLET_FIREFOX)
  end

  # ...but coarse bucketing has known blind spots, pinned here so a future
  # change to the heuristics surfaces as a deliberate test update:

  # iPadOS 13+ defaults to a desktop-class UA (reports as Macintosh, no "iPad"),
  # so it is indistinguishable from a Mac and reads as Desktop.
  def test_ipad_desktop_mode_reads_as_desktop
    assert_equal "Desktop", device(IPAD_DESKTOP_UA)
  end

  # Many Android tablets drop "Mobile" but never add "Tablet"; with only the
  # "Android" token to go on they read as Mobile.
  def test_android_tablet_without_tablet_token_reads_as_mobile
    assert_equal "Mobile", device(ANDROID_TABLET_CHROME)
  end

  # Crawlers and CLI tools carry no device hint, so they fall through to Desktop.
  def test_bots_and_tools_fall_through_to_desktop
    assert_equal "Desktop", device(GOOGLEBOT)
    assert_equal "Desktop", device(CURL)
  end

  def test_device_nil_and_empty_return_nil
    assert_nil device(nil)
    assert_nil device("")
  end

  # --- browser --------------------------------------------------------------

  def test_chrome
    assert_equal "Chrome", browser(CHROME_WIN)
    assert_equal "Chrome", browser(CHROME_MAC)
    assert_equal "Chrome", browser(CHROME_ANDROID)
  end

  def test_firefox
    assert_equal "Firefox", browser(FIREFOX_WIN)
    assert_equal "Firefox", browser(FIREFOX_ANDROID)
    assert_equal "Firefox", browser(ANDROID_TABLET_FIREFOX)
  end

  # Safari UAs contain "Safari/" but not "Chrome/", so they are not misread.
  def test_safari
    assert_equal "Safari", browser(SAFARI_MAC)
    assert_equal "Safari", browser(SAFARI_IPHONE)
    assert_equal "Safari", browser(IPAD_MOBILE_UA)
  end

  # Edge and Opera UAs both also contain "Chrome/" and "Safari/"; the rule
  # ordering must detect them by their own token before falling to Chrome.
  def test_edge_detected_before_chrome
    assert_equal "Edge", browser(EDGE_WIN)
  end

  def test_opera_detected_before_chrome
    assert_equal "Opera", browser(OPERA_WIN)
  end

  # Samsung Internet is not a recognised bucket; it carries "Chrome/" so it
  # coarsely reads as Chrome rather than Other.
  def test_samsung_internet_reads_as_chrome
    assert_equal "Chrome", browser(SAMSUNG_ANDROID)
  end

  def test_unknown_agents_are_other
    assert_equal "Other", browser(GOOGLEBOT)
    assert_equal "Other", browser(CURL)
  end

  def test_browser_nil_and_empty_return_nil
    assert_nil browser(nil)
    assert_nil browser("")
  end
end
