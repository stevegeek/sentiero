---
title: Authentication
nav_order: 2
description: Protecting the dashboard across Rails, Sinatra, and plain Rack.
---

# Authentication

## How Dashboard Authentication Works

On non-Rails frameworks, the Sentiero dashboard is **open to anyone by default**. Set `basic_auth`, `auth_callback`, or route-level auth before deploying. The Rails installer enables `basic_auth` by default (see below).

### `auth_callback`

The `auth_callback` configuration option receives the Rack `env` hash and should return a truthy value to allow access:

```ruby
Sentiero.configure do |config|
  config.auth_callback = ->(env) { env["rack.session"]&.dig("admin") }
end
```

The check lives in `Sentiero::Web::BaseApp` (shared by `DashboardApp`, `AnalyticsApp`, and all dashboard routes): a `nil` callback means open access, a truthy return allows the request, and a falsy return or a raised exception yields 403. It fails closed.

Key behaviors:

- **`nil` callback = open access.** Every request is allowed. This is the default.
- **Truthy return = allowed.** The double-bang (`!!`) coerces any truthy value.
- **Falsy return = 403 Forbidden.** Plain text response, no redirect.
- **Exceptions = 403.** If your callback raises, it's caught, logged to stderr, and treated as denied. Fail closed.

Every dashboard route checks `authorized?(env)` before proceeding. The only exception is `/assets/*` (static CSS/JS/images), which is intentionally public and has path traversal protection.

### `basic_auth`: Built-in HTTP Basic Auth

Setting `basic_auth` protects the dashboard and analytics UI directly at Sentiero's auth gate, no middleware wiring required, on any framework (Rails, Roda, Sinatra, plain Rack):

```ruby
Sentiero.configure do |config|
  config.basic_auth = { user: "admin", password: ENV["SENTIERO_DASHBOARD_PASSWORD"] }
end
```

Key behaviors:

- **Events and assets stay public.** Only the dashboard and analytics routes are protected.
- **Blank password raises `Sentiero::Error`.** If the configured password is blank (e.g., the env var is unset), Sentiero raises an error at request time rather than silently allowing access. Fail closed.
- **Returns `401` with `WWW-Authenticate`.** Browsers display their native login dialog. Wrong or missing credentials = 401; this is distinct from `auth_callback`'s 403.
- **`basic_auth` and `auth_callback` are independent.** When `basic_auth` is set it is the authority; `auth_callback` is only used when `basic_auth` is `nil`.
- **Rails enables this by default.** The `rails generate sentiero:install` generator produces an initializer with `config.basic_auth` active and prints a generated password for `SENTIERO_DASHBOARD_PASSWORD`. To disable, comment out the block.

Credentials are compared with `Rack::Utils.secure_compare` (constant-time, timing-safe). Assumes TLS terminated upstream. Do not deploy over plain HTTP.

A standalone `Sentiero::Web::BasicAuth` Rack middleware also exists for fully-standalone dashboard deployments where you want to mount the dashboard separately without the full Sentiero configuration object.

> **Open by default (non-Rails).** On Rails, `basic_auth` is enabled by the generator. On other frameworks, if neither `basic_auth` nor `auth_callback` is configured, the dashboard is accessible to anyone who can reach the URL. Always set at least one form of protection before deploying to production.

## The 403 Limitation

This is the most important thing to understand: **`auth_callback` always returns 403, never 401 or 302.**

This means:

| Auth type | Works with `auth_callback`? | Why |
|-----------|---------------------------|-----|
| Session-based (Devise, Warden, Rodauth, custom cookies) | **Yes** | User already has a session. 403 = "you're logged in but not allowed." |
| HTTP Basic Auth | **No** | Browsers need a `401` with `WWW-Authenticate` header to show the login dialog. 403 skips it. |
| OAuth / SSO redirects | **No** | Needs a `302` redirect to the auth provider. 403 is a dead end. |
| Token auth (API keys, Bearer tokens) | **Partially** | Works if the token is already in the request (e.g., header or cookie). Won't prompt for one. |

**When `auth_callback` won't work, use route-level auth.** Handle authentication in your framework's routing layer before the request reaches `DashboardApp`.

## Integration Examples

### Rails with Devise

**Option A: `auth_callback`** (if users are already signed in via Devise session)

```ruby
# config/initializers/sentiero.rb
Sentiero.configure do |config|
  config.auth_callback = ->(env) {
    warden = env["warden"]
    user = warden&.user
    user&.admin?
  }
end
```

```ruby
# config/routes.rb
mount Sentiero::Web::EventsApp.new => "/sentiero/events"
mount Sentiero::Web::DashboardApp.new => "/sentiero"
```

**Option B: Route constraint** (uses Devise's `authenticate` to redirect to login)

```ruby
# config/routes.rb
mount Sentiero::Web::EventsApp.new => "/sentiero/events"

# Serve recorder.js publicly; only the dashboard UI is gated.
mount Sentiero::Web::AssetsApp.new => "/sentiero/assets"

authenticate :user, ->(user) { user.admin? } do
  mount Sentiero::Web::DashboardApp.new => "/sentiero"
end
```

This is better if unauthenticated users should be redirected to the sign-in page rather than seeing a 403.

> **Warning: the `AssetsApp` mount is not optional here.** A route constraint gates *everything* under the mount path, including `/sentiero/assets/*` (the recorder JS, which `DashboardApp` would otherwise serve before its own auth check). Without the public `AssetsApp` mount, anonymous visitors get a 401/redirect on `recorder.js` and recording silently breaks for everyone except logged-in admins. If you don't need a login *redirect*, prefer `auth_callback` (Option A), where assets short-circuit before the callback runs and no separate mount is required.

### Rails with Custom Session Auth

```ruby
Sentiero.configure do |config|
  config.auth_callback = ->(env) {
    session = env["rack.session"]
    session && session["user_role"] == "admin"
  }
end
```

### Roda with HTTP Basic Auth

Set `config.basic_auth` in your Sentiero configuration. This is the pattern from the demo app (`demo/app.rb`):

```ruby
Sentiero.configure do |config|
  config.basic_auth = { user: ENV["DASHBOARD_USER"], password: ENV["DASHBOARD_PASSWORD"] }
end
```

No additional route-level wiring is needed. The dashboard routes are protected automatically, the events endpoint stays public, and browsers see a `401 WWW-Authenticate` challenge.

For session- or role-based auth (where you need a redirect rather than a Basic challenge), use `auth_callback` or route-level auth instead.

### Roda with Rodauth

**Option A: `auth_callback`** (session-based, user already logged in)

```ruby
Sentiero.configure do |config|
  config.auth_callback = ->(env) {
    scope = env["roda.rodauth"]   # depends on your Rodauth setup
    scope&.logged_in? && scope.account[:role] == "admin"
  }
end
```

**Option B: Route-level** (redirects to login page if not authenticated)

```ruby
class MyApp < Roda
  plugin :sentiero
  plugin :rodauth do
    # ... rodauth config
  end

  route do |r|
    r.on "sentiero" do
      r.on("events") { r.sentiero_events }

      rodauth.require_account
      unless rodauth.account[:role] == "admin"
        r.halt [403, {"content-type" => "text/plain"}, ["Forbidden"]]
      end

      r.sentiero_dashboard
    end
  end
end
```

### Sinatra

**Option A: `basic_auth`** (HTTP Basic, browser prompts for credentials)

```ruby
Sentiero.configure do |config|
  config.basic_auth = { user: ENV["DASHBOARD_USER"], password: ENV["DASHBOARD_PASSWORD"] }
end
```

No middleware wiring needed. Events and assets stay public; dashboard routes are protected.

**Option B: `auth_callback`** (session-based)

```ruby
Sentiero.configure do |config|
  config.auth_callback = ->(env) {
    env["rack.session"]&.dig("user", "admin")
  }
end
```

### Plain Rack

Use `config.basic_auth`; no middleware wiring needed:

```ruby
# config.ru / boot
Sentiero.configure do |config|
  config.basic_auth = { user: ENV["DASHBOARD_USER"], password: ENV["DASHBOARD_PASSWORD"] }
end

map "/sentiero/events" do
  run Sentiero::Web::EventsApp.new
end

map "/sentiero" do
  run Sentiero::Web::DashboardApp.new
end
```

For session-based checks (e.g., redirect to login), write standard Rack middleware that checks the session and either calls `@app.call(env)` or returns a 302, then wrap the dashboard mount with it:

```ruby
map "/sentiero" do
  use DashboardAuth   # your middleware: allow if logged in, else redirect to /login
  run Sentiero::Web::DashboardApp.new
end
```

## The Events Endpoint Is Public

`EventsApp` (`POST /sentiero/events`) has **no authentication by design**. It receives rrweb event data from the user's browser.

Why not add auth? The recorder JavaScript runs client-side. Any credentials embedded in client JS are visible to anyone who views source. A dedicated attacker can always POST fake events. Authentication would add complexity without meaningful security.

Instead, protect it with:

- **CORS origins:** `config.cors_origins = ["https://yoursite.com"]`. Browsers enforce this; won't stop curl but blocks cross-origin JS.
- **Rate limiting:** Use [Rack::Attack](https://github.com/rack/rack-attack) or nginx `limit_req` to throttle event submissions per IP.
- **Payload size limits:** Sentiero enforces a 512KB per-request limit. The recorder splits large payloads automatically.
- **Resource limits:** `max_events_per_request`, `max_sessions`, and `max_events_per_session` prevent unbounded storage growth.

## CSRF Protection

State-changing dashboard operations (delete, bulk delete) are protected by a double-submit cookie pattern:

1. The index page generates a random token and sets it as both a cookie (`sentiero_csrf`) and a hidden form field.
2. On submit, the server compares the cookie value to the form value using `Rack::Utils.secure_compare` (timing-safe).
3. Mismatch or missing values result in `403 Invalid CSRF token`.

Cookie attributes:
- `HttpOnly`: not accessible to JavaScript
- `SameSite=Strict`: only sent on same-site requests
- `Secure`: set automatically when served over HTTPS
- `Path`: scoped to the dashboard mount point

Read-only operations (GET requests) don't require CSRF tokens.

## Production Checklist

See the [Production Checklist](https://github.com/stevegeek/sentiero#production-checklist) in the README for the full list. Auth-specific items:

- Set `basic_auth` or `auth_callback`. On Rails the generator enables `basic_auth` by default. Do not deploy with an open dashboard.
- Set `cors_origins` to your frontend's origin(s).
- Add rate limiting on the events endpoint.
- Serve over HTTPS so the `Secure` flag is set on the CSRF cookie.
