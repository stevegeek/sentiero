---
title: Roda
nav_order: 2
description: Integrating Sentiero with Roda using the core sentiero gem.
---

# Roda

Use the core `sentiero` gem (not `sentiero-rails`) with Roda. The gem ships a Roda plugin that wires up request helpers and a view helper.

## 1. Add the gem

```ruby
# Gemfile
gem "sentiero"

# Pick a persistent store (optional for dev, required for production):
gem "redis", ">= 4.0"      # for Redis store
# or
gem "sqlite3", ">= 1.4"    # for SQLite store
```

## 2. Configure

Call `Sentiero.configure` once at boot, before your Roda app class is evaluated. The File store is a good default for development; Redis or SQLite for production.

```ruby
require "sentiero"
require "sentiero/stores/file"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::File.new(path: "tmp/sentiero_sessions")
  config.cors_origins = ["http://localhost:9292"]
end
```

For a Redis-backed store:

```ruby
require "sentiero"
require "redis"
require "sentiero/stores/redis"

Sentiero.configure do |config|
  config.store = Sentiero::Stores::Redis.new(
    redis: Redis.new(url: ENV.fetch("REDIS_URL")),
    ttl: 86_400 * 7   # auto-expire after 7 days
  )
  config.cors_origins = [ENV.fetch("APP_ORIGIN")]
end
```

See [Configuration](/guide/configuration/) for all options and [Storage Backends](/guide/storage/) for choosing a store.

## 3. Load the Roda plugin

```ruby
require "sentiero/roda"

class MyApp < Roda
  plugin :sentiero
  # ...
end
```

## 4. Mount the endpoints

Inside your `route` block, delegate to the Sentiero request helpers. The events endpoint must be public; protect the dashboard (see below).

```ruby
class MyApp < Roda
  plugin :sentiero

  route do |r|
    r.on "sentiero" do
      r.on("events") { r.sentiero_events }
      r.on("assets") { r.sentiero_assets }

      # Protect the dashboard with config.basic_auth (see Authentication below)
      r.on("dashboard") { r.sentiero_dashboard }
    end

    # ... your app routes
  end
end
```

The available request helpers (defined in `lib/sentiero/roda.rb`) are:

| Helper | Mounts |
|--------|--------|
| `r.sentiero_events` | `Sentiero::Web::EventsApp` (receives rrweb event batches) |
| `r.sentiero_dashboard` | `Sentiero::Web::DashboardApp` (session list and replay UI) |
| `r.sentiero_assets` | `Sentiero::Web::AssetsApp` (recorder JS and dashboard static assets) |
| `r.sentiero_analytics` | `Sentiero::Web::AnalyticsApp` (analytics UI only) |

## 5. Add the recorder script

The plugin adds `sentiero_script_tag` as an instance method. Call it in your layout view with the events endpoint URL:

```erb
<%# In your ERB layout, before </body> %>
<%= sentiero_script_tag(events_url: "/sentiero/events") %>
```

This renders the recorder's two script tags (a config JSON block and the loader); see [The Recorder](/guide/recorder/) for what they contain.

`recorder_url:` is optional; it defaults to the recorder asset served by `sentiero_assets`. Override it only if you serve the recorder JS from a CDN.

## Authentication

The dashboard has no authentication by default. Set `basic_auth` in your Sentiero configuration (the approach used in `demo/app.rb`); no route-level wiring is needed, since the dashboard routes are gated automatically while events and assets stay public:

```ruby
Sentiero.configure do |config|
  config.basic_auth = { user: ENV["DASHBOARD_USER"], password: ENV["DASHBOARD_PASSWORD"] }
end
```

For session- or role-based auth (e.g. Rodauth, where you need a redirect) set `config.auth_callback` instead. See [Authentication](/guide/authentication/) for the full guide, including Rodauth examples and the trade-offs between the two approaches.
