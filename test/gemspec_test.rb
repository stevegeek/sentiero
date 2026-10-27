# frozen_string_literal: true

require "test_helper"

# The two gems share one lib/ tree in this repo but install into separate
# directories, so a require_relative that resolves here can fail once packaged.
class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  %w[sentiero sentiero-rails].each do |name|
    define_method(:"test_#{name.tr("-", "_")}_require_relatives_stay_inside_the_gem") do
      files = Gem::Specification.load(File.join(ROOT, "#{name}.gemspec")).files
      ruby_files = files.select { |f| f.end_with?(".rb", ".rake") && !f.include?("/templates/") }

      escaping = ruby_files.flat_map do |file|
        File.read(File.join(ROOT, file)).scan(/^\s*require_relative\s+["']([^"']+)["']/).flatten.filter_map do |target|
          resolved = File.expand_path(target, File.dirname(File.join(ROOT, file)))
          resolved += ".rb" unless resolved.end_with?(".rb")
          relative = resolved.delete_prefix("#{ROOT}/")
          "#{file} -> #{relative}" unless files.include?(relative)
        end
      end

      assert_empty escaping, "require_relative targets outside the #{name} gem; use require instead"
    end
  end
end
