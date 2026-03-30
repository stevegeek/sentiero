# Geo-Location Support

Sentiero can capture geographic location data for each session, allowing you to understand where your users are located and filter sessions by country, city, or region.

Two geo-location strategies are supported out of the box:

| Strategy | Dependencies | Accuracy | Setup |
|----------|-------------|----------|-------|
| **Cloudflare** (default) | None — reads HTTP headers | Depends on Cloudflare plan | Deploy behind Cloudflare |
| **MaxMind GeoIP2** | `maxmind-geoip2` gem + database file | High (city-level) | Download GeoLite2 database |

You can also provide a custom resolver (any object responding to `#resolve(request)`).

---

## Cloudflare (default)

If your application is behind [Cloudflare](https://www.cloudflare.com/), Sentiero automatically reads the geo-location headers that Cloudflare injects into every request.

### Quick start

```ruby
# config.ru or application setup
require "sentiero"

# Cloudflare is the default — no configuration needed
use Sentiero::Middleware::GeoCapture

run MyApp
```

The middleware stores geo data in the Rack env:

```ruby
# In your application
geo = request.env["sentiero.geo_location"]
geo.country_code  # => "US"
geo.city           # => "San Francisco"

metadata = request.env["sentiero.session_metadata"]
metadata.to_h  # => { geo_location: { country_code: "US", ... }, user_agent: "...", ... }
```

### Cloudflare headers captured

| Header | Field | Cloudflare Plan |
|--------|-------|-----------------|
| `CF-IPCountry` | `country_code` | All plans (Free, Pro, Business, Enterprise) |
| `CF-Connecting-IP` | `ip` | All plans |
| `CF-IPCity` | `city` | Business and Enterprise only |
| `CF-Region` | `region` | Business and Enterprise only |
| `CF-Region-Code` | `region_code` | Business and Enterprise only |
| `CF-Postal-Code` | `postal_code` | Business and Enterprise only |
| `CF-Timezone` | `timezone` | Business and Enterprise only |
| `CF-IPLatitude` | `latitude` | Business and Enterprise only |
| `CF-IPLongitude` | `longitude` | Business and Enterprise only |

### Enabling Cloudflare geo headers

**`CF-IPCountry` is included on all Cloudflare plans** — no extra configuration needed.

For the detailed headers (city, region, coordinates), you need a **Business** or **Enterprise** plan with the "IP Geolocation" managed transform enabled:

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com/)
2. Go to **Rules → Transform Rules → Managed Transforms**
3. Enable **"Add visitor location headers"**

This adds all the `CF-IPCity`, `CF-Region`, `CF-Timezone`, etc. headers to incoming requests.

> **Note:** If your app is not behind Cloudflare, the resolver returns `nil` and no geo data is captured. The middleware still populates `user_agent` and `referrer` in the session metadata.

---

## MaxMind GeoIP2

For applications not behind Cloudflare, or when you want consistent geo data regardless of your CDN, you can use a [MaxMind GeoLite2](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database.

### Setup

**1. Install the gem:**

```ruby
# Gemfile
gem "maxmind-geoip2"
```

**2. Download the GeoLite2-City database:**

MaxMind requires a free account to download:

1. Sign up at [maxmind.com/en/geolite2/signup](https://www.maxmind.com/en/geolite2/signup)
2. Generate a license key under **Services → My License Key**
3. Download GeoLite2-City from **Download Databases** (choose the `.mmdb` format)

Or use `geoipupdate` to automate downloads:

```bash
# Install geoipupdate (Homebrew)
brew install geoipupdate

# Configure ~/.config/GeoIP.conf with your account ID and license key:
# AccountID YOUR_ACCOUNT_ID
# LicenseKey YOUR_LICENSE_KEY
# EditionIDs GeoLite2-City

# Download/update the database
geoipupdate
```

The database is typically stored at `/usr/share/GeoIP/GeoLite2-City.mmdb` or a path of your choosing.

**3. Configure Sentiero:**

```ruby
Sentiero.configure do |config|
  config.geo_resolver = :maxmind
  config.maxmind_database_path = "/path/to/GeoLite2-City.mmdb"
end

use Sentiero::Middleware::GeoCapture
```

The MaxMind resolver provides `country_name` in addition to `country_code` (Cloudflare only provides the code).

### Keeping the database updated

The GeoLite2 database is updated weekly. Set up a cron job to run `geoipupdate` regularly:

```cron
# Update GeoIP database weekly on Sundays at 3am
0 3 * * 0 /usr/local/bin/geoipupdate
```

> **Note:** The MaxMind reader is opened once when the middleware initializes. If you update the database file, you'll need to restart your application to pick up the new data.

---

## Custom resolver

You can provide any object that responds to `#resolve(request)` and returns a `Sentiero::GeoLocation` (or `nil`):

```ruby
class MyGeoResolver
  def resolve(request)
    # Your custom logic here
    Sentiero::GeoLocation.new(
      country_code: lookup_country(request.ip),
      city: lookup_city(request.ip)
    )
  end
end

Sentiero.configure do |config|
  config.geo_resolver = MyGeoResolver.new
end
```

---

## Privacy: disabling IP capture

By default, the client IP is stored in `GeoLocation#ip`. To capture geo data without retaining the IP address:

```ruby
Sentiero.configure do |config|
  config.capture_ip = false
end
```

This sets `ip` to `nil` in the resulting `GeoLocation`, while still populating country, city, and other geo fields.

---

## Filtering sessions by location

Use `Sentiero::GeoFilter` to filter session metadata by geographic fields:

```ruby
sessions = [session1.to_h, session2.to_h, session3.to_h]

# Filter by country
us_sessions = Sentiero::GeoFilter.by_country(sessions, "US")

# Filter by city
sf_sessions = Sentiero::GeoFilter.by_city(sessions, "San Francisco")

# Filter by region
ca_sessions = Sentiero::GeoFilter.by_region(sessions, "California")

# Filter by timezone
pst_sessions = Sentiero::GeoFilter.by_timezone(sessions, "America/Los_Angeles")

# Find sessions within 100km of a point
nearby = Sentiero::GeoFilter.within_radius(sessions,
  lat: 37.7749, lng: -122.4194, radius_km: 100
)
```

These methods operate on arrays of hashes (the output of `SessionMetadata#to_h`) and are storage-agnostic.

---

## GeoLocation fields reference

| Field | Type | Example | Source |
|-------|------|---------|--------|
| `country_code` | String | `"US"` | Both |
| `country_name` | String | `"United States"` | MaxMind only |
| `city` | String | `"San Francisco"` | Both |
| `region` | String | `"California"` | Both |
| `region_code` | String | `"CA"` | Both |
| `postal_code` | String | `"94107"` | Both |
| `timezone` | String | `"America/Los_Angeles"` | Both |
| `latitude` | Float | `37.7749` | Both |
| `longitude` | Float | `-122.4194` | Both |
| `ip` | String | `"203.0.113.1"` | Both (unless `capture_ip: false`) |
