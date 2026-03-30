# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.12"
  gem "rack-test", "~> 2.1"
  gem "rubocop", "~> 1.50"
end

group :test do
  # Optional: only needed when testing MaxMind resolver
  gem "maxmind-geoip2", require: false
end
