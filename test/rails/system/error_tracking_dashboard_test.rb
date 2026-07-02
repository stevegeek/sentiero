# frozen_string_literal: true

require_relative "../test_helper"
require_relative "system_helper"
require "json"
require "net/http"

class ErrorTrackingDashboardTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def setup
    Sentiero.reset_configuration!
    Sentiero.configure do |c|
      c.store = Sentiero::Rails::Store.new
      c.ingest_keys = {"k1" => "app"}
      c.auth_callback = nil
    end
    Sentiero::Rails::Problem.delete_all
    Sentiero::Rails::Occurrence.delete_all
    Sentiero::Rails::ServerEvent.delete_all
  end

  def teardown
    Capybara.reset_sessions!
    Capybara.use_default_driver
    Sentiero.reset_configuration!
  end

  def test_reported_error_appears_grouped_and_can_be_resolved
    # Ingest two occurrences of the same error via the mounted /sentiero/errors.
    server_base = page.server_url
    uri = URI.join(server_base, "/sentiero/errors")
    2.times do |i|
      http_post_json(uri, {"exception_class" => "NoMethodError",
        "message" => "undefined method foo (#{i})", "backtrace" => ["app/x.rb:14:in `show'"]},
        headers: {"Authorization" => "Bearer k1"})
    end

    visit "/sentiero/issues"
    assert_text "NoMethodError"

    click_link "NoMethodError"
    assert_text "occurrences" # the detail header shows the count
    assert_text "Resolve"     # Resolve button is present

    click_button "Resolve"
    assert_text "resolved" # status flips in the re-rendered page
  end

  def test_custom_events_page_lists_tracked_events
    server_base = page.server_url
    uri = URI.join(server_base, "/sentiero/track")
    http_post_json(uri, {"name" => "signup_completed", "level" => "info"},
      headers: {"Authorization" => "Bearer k1"})

    visit "/sentiero/custom-events"
    assert_text "Events"
    assert_text "signup_completed"
  end

  private

  def http_post_json(uri, body, headers: {})
    req = Net::HTTP::Post.new(uri)
    req["content-type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = JSON.generate(body)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end
end
