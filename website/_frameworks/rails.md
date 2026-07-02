---
title: Rails
nav_order: 1
description: The sentiero-rails gem adds ActiveRecord storage, generators, and view helpers.
---

# Rails

Sentiero ships as two gems. The core `sentiero` gem is framework-agnostic. The `sentiero-rails` gem adds an ActiveRecord store, a view helper, and an install generator.

## Installation

Add to your Gemfile:

```ruby
gem "sentiero-rails"
```

Run the install generator:

```bash
rails generate sentiero:install
rails db:migrate
```

The generator creates two files:

| File | Purpose |
|------|---------|
| `db/migrate/*_create_sentiero_tables.rb` | Creates five tables: `sentiero_sessions`, `sentiero_events`, `sentiero_problems`, `sentiero_occurrences`, and `sentiero_server_events` |
| `config/initializers/sentiero.rb` | Configuration with `basic_auth` enabled and other options as commented examples |

**Dashboard Basic Auth is enabled by default.** The generated initializer includes an active `config.basic_auth` block:

```ruby
config.basic_auth = { user: "admin", password: ENV["SENTIERO_DASHBOARD_PASSWORD"] }
```

The generator also prints a randomly generated password and the corresponding `export` command:

```bash
SENTIERO_DASHBOARD_PASSWORD=<generated>
export SENTIERO_DASHBOARD_PASSWORD=<generated>
```

Set this environment variable before starting your server, or the dashboard will raise `Sentiero::Error` when accessed (fail closed; a blank password is never silently accepted). To disable Basic Auth entirely, comment out the `config.basic_auth` block in the initializer and configure `auth_callback` or route-level auth instead.

## Database Tables

The migration creates five tables: `sentiero_sessions` and `sentiero_events` hold recording sessions and their rrweb events; `sentiero_problems` and `sentiero_occurrences` hold grouped server-side errors and their individual occurrences; `sentiero_server_events` holds server-side structured events (logs, audit entries). See [ActiveRecord Store](/guide/storage/#activerecord-store) for the column-by-column schema and indexes.

## ActiveRecord Store

When `sentiero-rails` is loaded, the engine automatically sets `Sentiero::Rails::Store.new` as the default store if you haven't configured one explicitly. You don't need to set `config.store` unless you want to use Redis or Memory instead; see [Storage Backends](/guide/storage/) for the alternatives.

The AR store uses `insert_all` for bulk event writes and wraps each `save_events` call in a transaction.

### LRU Eviction

Two limits from `Sentiero.configuration` are enforced inside each `save_events` transaction:

| Config | Behavior |
|--------|----------|
| `max_sessions` | When exceeded, oldest sessions (by `updated_at`) are deleted. The session being written to is protected. |
| `max_events_per_session` | When exceeded, oldest events (by `timestamp`) within the session are deleted. |

Both default to `nil` (unlimited). Set them in your initializer for production.

### Cleanup

For time-based cleanup, use the built-in rake task loaded by the engine. Set `config.retention_period` (in seconds) in your initializer, then schedule:

```bash
rake sentiero:purge   # deletes sessions older than retention_period (irreversible)
```

For GDPR erasure of specific sessions or a time range:

```bash
rake sentiero:erase SESSION_IDS=id1,id2
rake sentiero:erase SINCE=2024-01-01 UNTIL=2024-06-01
```

If you need manual AR-level cleanup as an alternative (e.g., in a Sidekiq cron job that runs its own queries), you can delete directly:

```ruby
Sentiero::Rails::Event.where("created_at < ?", 30.days.ago).delete_all
Sentiero::Rails::Session.left_joins(:events)
  .where(sentiero_events: { id: nil }).delete_all
```

## Two Configuration Objects

Sentiero has two separate configuration namespaces. Do not confuse them.

**`Sentiero.configure`** -- core configuration. Controls the store, CORS, auth, privacy, recorder options, and resource limits. This is the same object used by all frameworks.

**`Sentiero::Rails.configure`** -- Rails-specific. Two options:

```ruby
Sentiero::Rails.configure do |config|
  config.events_url = "/sentiero/events"  # default
  config.reporter_middleware = true        # default; set false to opt out
end
```

`events_url` is only used by the `sentiero_script_tag` view helper to set the default endpoint URL. If you pass `events_url:` directly to the helper, this config is ignored.

`reporter_middleware` controls whether the engine auto-inserts `Sentiero::Reporter::Middleware` into the Rails middleware stack. Defaults to `true`; the middleware only activates if the reporter is also configured and active. Set to `false` to manage the middleware manually.

## View Helper

The engine injects `sentiero_script_tag` into all views via `ActionView`. Add it to your layout before `</body>`:

```erb
<!-- app/views/layouts/application.html.erb -->
<body>
  <%= yield %>
  <%= sentiero_script_tag %>
</body>
```

This renders the recorder's two script tags (a config JSON block and the loader). The `events_url` defaults to `Sentiero::Rails.configuration.events_url` (`"/sentiero/events"`). See [The Recorder](/guide/recorder/) for what the tags contain.

To override:

```erb
<%= sentiero_script_tag(events_url: "/custom/events/path") %>
```

## Routing

Mount both Rack apps in `config/routes.rb`. The events endpoint must be public (it receives browser-generated recording data). The dashboard should be protected.

```ruby
# config/routes.rb
mount Sentiero::Web::EventsApp.new => "/sentiero/events"

# Option A: mount openly, protect via basic_auth or auth_callback in the initializer
mount Sentiero::Web::DashboardApp.new => "/sentiero"

# Option B: protect via a Devise route constraint (see warning below)
# authenticate :user, ->(u) { u.admin? } do
#   mount Sentiero::Web::DashboardApp.new => "/sentiero"
# end
```

The events endpoint path must match the `events_url` used by the script tag helper (default: `"/sentiero/events"`). The dashboard must be mounted at a path that is a prefix of the events path minus `/events` (default: `"/sentiero"`).

### Why the mount path matters for assets

The recorder JS is served from `/sentiero/assets/recorder-<hash>.js`. The script tag derives that URL from the events URL minus `/events`, and `DashboardApp` serves `/assets/*` itself, **before** its auth check, so the recorder stays public even when the dashboard is protected by `auth_callback` or `basic_auth`.

> **Warning: do not wrap the dashboard mount in a route constraint.** A Rails `authenticate`/route constraint (Option B above) gates *everything* under the mount path, including `/sentiero/assets/*`. Anonymous visitors then get a 401/redirect on `recorder.js` and recording silently breaks for everyone except logged-in admins. Two safe ways to require a login redirect instead:
>
> 1. Use `config.basic_auth` or `config.auth_callback` (assets short-circuit before the callback runs), or
> 2. Mount the public assets endpoint outside the constraint:
>
> ```ruby
> # Serve recorder.js publicly, gate only the dashboard UI
> mount Sentiero::Web::AssetsApp.new => "/sentiero/assets"
>
> authenticate :user, ->(u) { u.admin? } do
>   mount Sentiero::Web::DashboardApp.new => "/sentiero"
> end
> ```

## Authentication

The generator enables `basic_auth` by default (see [Installation](#installation)). For session-based auth (Devise, Warden), set `auth_callback` in `Sentiero.configure` instead:

```ruby
Sentiero.configure do |config|
  config.auth_callback = ->(env) { env["warden"]&.authenticated? && env["warden"].user.admin? }
end
```

Route-level auth (a Devise `authenticate` block) can redirect to a login page, but it gates `/sentiero/assets/*` and breaks recording for anonymous visitors unless you mount `Sentiero::Web::AssetsApp` publicly outside the constraint. See the warning under [Routing](#why-the-mount-path-matters-for-assets).

The events endpoint is intentionally unauthenticated; protect it with CORS and rate limiting. See [Authentication](/guide/authentication/) for the full guide (Devise examples, the 403 limitation, CSRF, and the production checklist).
