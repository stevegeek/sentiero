# frozen_string_literal: true

require_relative "lib/sentiero/version"

Gem::Specification.new do |spec|
  spec.name = "sentiero"
  spec.version = Sentiero::VERSION
  spec.authors = ["Sentiero Contributors"]
  spec.summary = "In-app browser session recording and replay for Ruby"
  spec.description = "Self-hosted, privacy-first session recording and replay. " \
                     "Framework-agnostic Rack middleware with pluggable storage backends."
  spec.homepage = "https://github.com/stevegeek/sentiero"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "docs/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", ">= 2.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }

  spec.post_install_message = <<~MSG
    Sentiero installed successfully!

    For MaxMind GeoIP2 support, also install: gem install maxmind-geoip2
    See docs/geo_location.md for setup instructions.
  MSG
end
