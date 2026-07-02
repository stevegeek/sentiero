# frozen_string_literal: true

require_relative "lib/sentiero/version"

Gem::Specification.new do |spec|
  spec.name = "sentiero-rails"
  spec.version = Sentiero::VERSION
  spec.authors = ["Stephen Ierodiaconou"]
  spec.email = ["stevegeek@gmail.com"]
  spec.summary = "Rails integration for Sentiero browser session recording"
  spec.description = "Rails engine providing ActiveRecord storage, view helpers, " \
    "and generators for the Sentiero session recording gem."
  spec.homepage = "https://github.com/stevegeek/sentiero"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  # Ship only git-tracked Rails-engine source plus the license. No compiled
  # assets here: those live in the core sentiero gem.
  tracked = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL, &:read).split("\x0")
  spec.files = tracked.select { |f|
    File.file?(File.join(__dir__, f)) &&
      (f == "lib/sentiero/rails.rb" || f.start_with?("lib/sentiero/rails/") || f == "LICENSE.txt")
  }
  spec.require_paths = ["lib"]

  spec.add_dependency "sentiero", "~> #{Sentiero::VERSION}"
  spec.add_dependency "railties", ">= 7.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
end
