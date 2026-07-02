---
title: Quick Start
nav_order: 2
description: Install Sentiero and start recording sessions in under a minute.
---

# Quick Start

This guide gets you recording with the `sentiero-rails` gem. Using Roda or Sinatra? See the [Roda guide](/guide/roda/) or the [Sinatra guide](/guide/sinatra/); the core `sentiero` gem works with any Rack app.

## 1. Add the gem

```ruby
# Gemfile
gem "sentiero-rails"
```

## 2. Run the install generator

```bash
bundle install
rails generate sentiero:install
rails db:migrate
```

The generator creates a configuration initializer and a migration. The engine automatically configures `Sentiero::Rails::Store` (ActiveRecord-backed) as the default store, so you don't need to set `config.store` yourself unless you want Redis or another backend.

## 3. Set the dashboard password

The generator enables HTTP Basic Auth on the dashboard and prints a generated password plus an `export` line. Set it before booting, or the dashboard raises `Sentiero::Error` on first access (it fails closed; a blank password is never silently accepted):

```bash
export SENTIERO_DASHBOARD_PASSWORD=<the value the generator printed>
```

## 4. Mount the routes

```ruby
# config/routes.rb
mount Sentiero::Web::EventsApp.new => "/sentiero/events"
mount Sentiero::Web::DashboardApp.new => "/sentiero"
```

> **The dashboard is protected by default on Rails.** The generator's Basic Auth covers `/sentiero`. The events endpoint at `/sentiero/events` stays public by design (the browser must POST recordings to it). On non-Rails Rack apps the dashboard is open by default, so set `config.basic_auth` or `config.auth_callback` yourself. See [Authentication](/guide/authentication/).

## 5. Add the recorder to your layout

Add the helper before `</body>` in the layout that actually renders for your users:

```erb
<%# app/views/layouts/application.html.erb %>
<body>
  <%= yield %>
  <%= sentiero_script_tag %>
</body>
```

That's it; sessions start recording on the next page load.

## Next steps

- [Configuration](/guide/configuration/): tune flush intervals, limits, and opt-in features.
- [Privacy & Masking](/guide/privacy/): review the defaults before going to production.
- [Storage & Retention](/guide/configuration/): `retention_period`, `max_sessions`, and `max_events_per_session` all default to unlimited; set them before production so storage stays bounded.
- [Authentication](/guide/authentication/): protect the dashboard.
- [Analytics](/guide/analytics/): explore cross-session insights.
