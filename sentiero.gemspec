# frozen_string_literal: true

require_relative "lib/sentiero/version"

Gem::Specification.new do |spec|
  spec.name = "sentiero"
  spec.version = Sentiero::VERSION
  spec.authors = ["Stephen Ierodiaconou"]
  spec.email = ["stevegeek@gmail.com"]
  spec.summary = "Browser session recording for Ruby. Like Hotjar etc."
  spec.description = "Record and replay browser sessions using rrweb. " \
    "Pluggable storage, privacy-first defaults, " \
    "Rack-based endpoints. Works with any Rack framework. Rails support via sentiero-rails."
  spec.homepage = "https://github.com/stevegeek/sentiero"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  # Ship git-tracked source (so untracked temp files never leak) plus the
  # compiled frontend bundle, which is gitignored but required at runtime.
  tracked = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL, &:read).split("\x0")
  assets = Dir.chdir(__dir__) { Dir["lib/sentiero/web/assets/**/*"] }

  if File.basename($PROGRAM_NAME) == "gem" &&
      !File.file?(File.join(__dir__, "lib/sentiero/web/assets/manifest.json"))
    raise "sentiero.gemspec: compiled frontend assets are missing " \
      "(lib/sentiero/web/assets/manifest.json not found). Run `bin/build` or " \
      "`cd frontend && npm run build` before building the gem."
  end
  spec.files = (tracked + assets).uniq.select { |f|
    File.file?(File.join(__dir__, f)) &&
      (f.start_with?("lib/") || %w[LICENSE.txt README.md].include?(f))
  }.reject { |f| f.start_with?("lib/sentiero/rails") }
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", ">= 2.0", "< 4.0"
  spec.add_dependency "concurrent-ruby", "~> 1.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
end
