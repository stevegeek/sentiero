# frozen_string_literal: true

require "dotenv"
Dotenv.load(".env", ".env.demo")
require "roda"
require "securerandom"
require "sentiero"
require "sentiero/roda"

def build_store
  if ENV["REDIS_URL"]
    require "redis"
    require "sentiero/stores/redis"
    redis = ::Redis.new(url: ENV["REDIS_URL"])
    redis.ping
    puts "==> Using Redis store (#{ENV["REDIS_URL"]})"
    Sentiero::Stores::Redis.new(redis: redis, ttl: ENV.fetch("REDIS_TTL", 86_400).to_i)
  else
    build_file_store
  end
rescue => e
  puts "==> Redis unavailable (#{e.message}), falling back to file store"
  build_file_store
end

def build_file_store
  require "sentiero/stores/file"
  path = File.join(__dir__, "tmp", "sentiero_sessions")
  puts "==> Using File store (#{path}). Set REDIS_URL to use Redis."
  Sentiero::Stores::File.new(path: path)
end

DASHBOARD_USER = ENV.fetch("DASHBOARD_USER", "demo")
DASHBOARD_PASSWORD = ENV.fetch("DASHBOARD_PASSWORD", "demo")

Sentiero.configure do |config|
  config.store = build_store
  config.cors_origins = ["http://localhost:#{ENV.fetch("PORT", 9292)}"]
  config.flush_interval_ms = 5_000
  config.flush_event_threshold = 30
  config.max_events_per_page = 500
  config.track_custom_events = true
  config.capture_metadata = true
  config.capture_errors = true
  config.capture_web_vitals = true
  config.capture_clicks = true
  config.track_navigation = true
  config.track_forms = true
  config.shareable_replays = true
  config.user_opt_out = true
  config.ingest_keys = {"demo-ingest-key" => "demo"}
  config.basic_auth = {user: DASHBOARD_USER, password: DASHBOARD_PASSWORD}

  # Server-side scrubbing runs through the built-in redaction engine on every
  # ingest: the default url_mode :strip drops URL query strings and the builtin
  # text patterns redact emails/tokens, so the demo needs no extra config.
  # Customize via config.redaction (custom_patterns, server_proc, url_mode).
end

class TodoApp < Roda
  plugin :sentiero
  plugin :render, engine: "erb", views: File.join(__dir__, "views")
  plugin :sessions, secret: ENV.fetch("SESSION_SECRET"), key: "todo.session"
  plugin :route_csrf
  plugin :h

  route do |r|
    r.on "sentiero" do
      r.on "events" do
        r.sentiero_events
      end

      r.on "assets" do
        r.sentiero_assets
      end

      r.on "errors" do
        r.run Sentiero::Web::ErrorsApp.new
      end

      r.on "track" do
        r.run Sentiero::Web::TrackApp.new
      end

      r.on "dashboard" do
        r.sentiero_dashboard
      end
    end

    session["todos"] ||= []

    # Marketing landing page: long + scrollable so scroll-depth and
    # page-position heatmaps have something to show. CTA fires `cta_clicked`.
    r.root do
      @page_title = "Trailhead — Sentiero Demo"
      @full_width = true
      view "landing"
    end

    # Signup form: fires `plan_selected` (on plan change, numeric price
    # payload) and `signup_completed` (on submit), then drops into the app.
    r.on "signup" do
      r.get true do
        @page_title = "Sign up — Trailhead"
        view "signup"
      end

      r.post true do
        check_csrf!
        name = r.params["name"]&.strip
        session["user_name"] = name if name && !name.empty?
        session["plan"] = r.params["plan"]
        r.redirect "/app"
      end
    end

    # The todo app itself (the funnel's activation step lives here:
    # adding a todo fires `todo_created`).
    r.get "app" do
      @page_title = "Todos — Trailhead"
      @user_name = session["user_name"]
      @todos = session["todos"]
      view "todos"
    end

    r.post "todos" do
      check_csrf!
      text = r.params["text"]&.strip
      if text && !text.empty?
        session["todos"] << {
          "id" => SecureRandom.hex(8),
          "text" => text,
          "done" => false,
          "created_at" => Time.now.to_s
        }
      end
      r.redirect "/app"
    end

    r.post "todos", String, "toggle" do |id|
      check_csrf!
      todo = session["todos"].find { |t| t["id"] == id }
      todo["done"] = !todo["done"] if todo
      r.redirect "/app"
    end

    r.post "todos", String, "delete" do |id|
      check_csrf!
      session["todos"].reject! { |t| t["id"] == id }
      r.redirect "/app"
    end
  end
end
