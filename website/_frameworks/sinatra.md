---
title: Sinatra / Rack
nav_order: 3
description: Integrating Sentiero with Sinatra or plain Rack using the core sentiero gem.
---

# Sinatra / Rack

Use the core `sentiero` gem (not `sentiero-rails`). There is no Sinatra-specific plugin; mount the Sentiero Rack apps directly.

## 1. Add the gem

```ruby
# Gemfile
gem "sentiero"

# Pick a persistent store:
gem "redis", ">= 4.0"    # for Redis store
# or
gem "sqlite3", ">= 1.4"  # for SQLite store
```

## 2. Configure

Call `Sentiero.configure` once at boot:

```ruby
require "sentiero"
require "sentiero/stores/sqlite"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::SQLite.new(path: "sentiero.db")
  config.cors_origins = [ENV.fetch("APP_ORIGIN", "http://localhost:9292")]
end
```

See [Configuration](/guide/configuration/) for all options and [Storage Backends](/guide/storage/) for choosing a store.

## 3. Mount the endpoints

### Plain Rack (`config.ru`)

Use `map` to route each Sentiero app to a path prefix:

```ruby
# config.ru
require_relative "your_app"

map "/sentiero/events" do
  run Sentiero::Web::EventsApp.new
end

map "/sentiero/assets" do
  run Sentiero::Web::AssetsApp.new
end

map "/sentiero" do
  # Protect the dashboard with config.basic_auth (see Authentication below)
  run Sentiero::Web::DashboardApp.new
end

run YourApp
```

### Sinatra

The same three `map` blocks apply. The only difference: add a root `map "/"` block for Sinatra's own app and `require "sinatra"` at the top. Replace `run YourApp` with `map "/" do; run Sinatra::Application; end`.

## 4. Add the recorder script

There is no Sinatra-specific helper. Call `Sentiero::Web::ScriptTag.render` directly and output the result in your layout:

```ruby
# In a Sinatra helper or layout helper
helpers do
  def sentiero_script_tag(events_url:)
    Sentiero::Web::ScriptTag.render(events_url: events_url)
  end
end
```

Then in your ERB layout:

```erb
<%# In your layout, before </body> %>
<%= sentiero_script_tag(events_url: "/sentiero/events") %>
```

This renders the recorder's two script tags (a config JSON block and the loader); see [The Recorder](/guide/recorder/) for what they contain. `recorder_url:` is optional; it defaults to the content-hashed recorder asset under `/sentiero/assets/` (resolved via the asset manifest, e.g. `recorder-TBGP22CQ.js`), and there is no stable un-hashed `recorder.js`.

## Authentication

The dashboard has no authentication by default. Set `basic_auth` in your Sentiero configuration (no middleware wiring needed); the dashboard and analytics routes are gated automatically while events and assets stay public:

```ruby
Sentiero.configure do |config|
  config.basic_auth = { user: ENV["DASHBOARD_USER"], password: ENV["DASHBOARD_PASSWORD"] }
end
```

For session-based auth, set `config.auth_callback` instead. See [Authentication](/guide/authentication/) for the full guide, including the trade-offs between the two approaches.
