# frozen_string_literal: true

require "capybara/minitest"
require "capybara/cuprite"

# Browser path: SENTIERO_TEST_CHROME overrides; otherwise nil lets Ferrum
# auto-detect a local Chrome/Chromium.
browser_path = ENV["SENTIERO_TEST_CHROME"]

Capybara.register_driver :cuprite_headless do |app|
  options = {
    headless: true,
    process_timeout: 30,
    timeout: 15,
    browser_options: {"no-sandbox" => nil, "disable-gpu" => nil}
  }
  options[:browser_path] = browser_path if browser_path
  Capybara::Cuprite::Driver.new(app, **options)
end

Capybara.default_driver = :cuprite_headless
Capybara.javascript_driver = :cuprite_headless
Capybara.app = Rails.application
Capybara.server = :webrick
