# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "sentiero"
gemspec name: "sentiero-rails"

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rack-test", "~> 2.0"
  gem "standard", "~> 1.40"
  gem "bundler-audit", "~> 0.9"
end

group :test do
  gem "dotenv", ">= 2.0"
  gem "redis", ">= 4.0"
  gem "sqlite3", ">= 1.4"
  gem "capybara", ">= 3.39"
  gem "cuprite", "~> 0.15"
  gem "simplecov", ">= 0.22", require: false
  gem "rubycritic", require: false
end
