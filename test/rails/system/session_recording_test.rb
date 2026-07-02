# frozen_string_literal: true

require_relative "../test_helper"
require_relative "system_helper"

class SessionRecordingTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def setup
    Sentiero.reset_configuration!
    Sentiero.configure do |c|
      c.store = Sentiero::Rails::Store.new
      c.flush_interval_ms = 500
      c.flush_event_threshold = 2
      c.auth_callback = nil
    end
    Sentiero::Rails::Session.delete_all
    Sentiero::Rails::Event.delete_all
  end

  def teardown
    Capybara.reset_sessions!
    Capybara.use_default_driver
    Sentiero.reset_configuration!
  end

  def test_records_session_and_shows_in_dashboard_with_playback_events
    # 1. Visit page,  recorder starts, captures full DOM snapshot
    visit "/"
    assert_text "Test Page"

    # 2. Interact,  click a button, fill inputs, check a checkbox
    fill_in "Name", with: "Test User"
    fill_in "Email", with: "test@example.com"
    check "I agree"
    click_button "Click Me"

    # 3. Wait for event flush (500ms interval + network round-trip)
    sleep 3

    # 4. Verify session was stored
    sessions = Sentiero.store.list_sessions(limit: 10)
    assert_equal 1, sessions.size, "Expected exactly 1 session, got #{sessions.size}"
    session = sessions.first
    assert session[:event_count] > 0, "Expected events to be recorded, got #{session[:event_count]}"

    # 5. Visit dashboard,  verify session appears
    visit "/sentiero/"
    assert_text session[:session_id][0, 8]

    # 6. Click into session,  navigate to replay page
    click_link session[:session_id][0, 8]
    assert_text "Delete recording" # replay page renders session details + delete button

    # 7. Verify events contain expected rrweb types
    window_id = session[:window_ids].first
    events = Sentiero.store.get_events(Sentiero::WindowRef.new(session[:session_id], window_id))
    assert events.size > 0, "Expected events in store"

    # rrweb type 2 = FullSnapshot (always captured on page load)
    has_full_snapshot = events.any? { |e| e["type"] == 2 }
    assert has_full_snapshot, "Expected FullSnapshot event (type 2)"

    # rrweb type 3 = IncrementalSnapshot (inputs, clicks, mutations)
    has_incremental = events.any? { |e| e["type"] == 3 }
    assert has_incremental, "Expected IncrementalSnapshot events (type 3)"

    # 8. Verify events API returns valid JSON (via rack_test for direct HTTP check)
    env = Rack::MockRequest.env_for(
      "/api/sessions/#{session[:session_id]}/windows/#{window_id}/events"
    )
    status, headers, body = Sentiero::Web::DashboardApp.new.call(env)
    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    api_events = JSON.parse(body.first)
    assert api_events.size > 0, "Expected events in API response"
  end

  def test_declarative_custom_event_tracking
    # Enable declarative tracking
    Sentiero.configure do |c|
      c.store = Sentiero::Rails::Store.new
      c.flush_interval_ms = 500
      c.flush_event_threshold = 2
      c.track_custom_events = true
    end

    # 1. Visit page with declarative tracking elements
    visit "/"
    assert_text "Test Page"
    assert_text "Declarative Custom Events"

    # 2. Click button with data-sentiero-track-click and data-sentiero-data
    click_button "Choose Pro (with payload)"

    # 3. Wait for event flush
    sleep 3

    # 4. Get recorded events
    sessions = Sentiero.store.list_sessions(limit: 10)
    assert_equal 1, sessions.size, "Expected 1 session"
    session = sessions.first
    window_id = session[:window_ids].first
    events = Sentiero.store.get_events(Sentiero::WindowRef.new(session[:session_id], window_id))

    # 5. Find the custom event (rrweb type 5 = CustomEvent)
    custom_events = events.select { |e| e["type"] == 5 }
    plan_event = custom_events.find { |e| e.dig("data", "tag") == "plan_selected" }

    assert plan_event, "Expected a custom event with tag 'plan_selected'. " \
      "Custom events found: #{custom_events.map { |e| e.dig("data", "tag") }.inspect}"

    payload = plan_event.dig("data", "payload")
    assert_equal "pro", payload["plan"], "Expected payload plan=pro"
    assert_equal 29, payload["price"], "Expected payload price=29"
  end

  def test_declarative_custom_event_tracking_disabled_by_default
    # track_custom_events defaults to false,  declarative attributes should be inert
    visit "/"
    assert_text "Test Page"

    click_button "Choose Pro (with payload)"

    sleep 3

    sessions = Sentiero.store.list_sessions(limit: 10)
    assert_equal 1, sessions.size
    session = sessions.first
    window_id = session[:window_ids].first
    events = Sentiero.store.get_events(Sentiero::WindowRef.new(session[:session_id], window_id))

    custom_events = events.select { |e|
      e["type"] == 5 && e.dig("data", "tag") == "plan_selected"
    }
    assert_empty custom_events,
      "Expected no 'plan_selected' custom events when track_custom_events is disabled"
  end

  def test_selective_unmasking_records_unmasked_inputs_in_plaintext
    # Visit page with masked + unmasked inputs
    visit "/unmasking"
    assert_text "Selective Unmasking Test"

    # Fill inputs with distinctive values
    fill_in "Masked Field", with: "SecretValue"
    fill_in "Unmasked Field", with: "PublicValue"
    fill_in "Password", with: "HiddenPass"
    fill_in "Unmasked Password", with: "VisiblePass"
    click_button "Submit"

    # Wait for event flush
    sleep 3

    # Get recorded events
    sessions = Sentiero.store.list_sessions(limit: 10)
    assert_equal 1, sessions.size, "Expected 1 session"
    session = sessions.first
    window_id = session[:window_ids].first
    events = Sentiero.store.get_events(Sentiero::WindowRef.new(session[:session_id], window_id))

    # Extract rrweb IncrementalSnapshot Input events (type=3, data.source=5)
    input_events = events.select { |e|
      e["type"] == 3 && e.dig("data", "source") == 5
    }
    assert input_events.size > 0, "Expected IncrementalSnapshot Input events"

    input_texts = input_events.map { |e| e.dig("data", "text") }.compact

    # Unmasked field: plaintext value should appear in recorded events
    assert input_texts.any? { |t| t == "PublicValue" },
      "Expected unmasked input 'PublicValue' to appear in plaintext in recorded events. " \
      "Got input texts: #{input_texts.inspect}"

    # Masked field: plaintext "SecretValue" must NOT appear,  should be asterisks
    refute input_texts.any? { |t| t == "SecretValue" },
      "Masked input 'SecretValue' should NOT appear in plaintext in recorded events"

    # Masked field: asterisks of matching length should appear
    assert input_texts.any? { |t| t == "*" * "SecretValue".length },
      "Expected masked input to appear as '***********' (11 asterisks). " \
      "Got input texts: #{input_texts.inspect}"

    # Password without unmask: plaintext "HiddenPass" must NOT appear
    refute input_texts.any? { |t| t == "HiddenPass" },
      "Password 'HiddenPass' should NOT appear in plaintext in recorded events"
  end
end
