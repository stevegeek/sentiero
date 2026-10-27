# frozen_string_literal: true

if ENV["COVERAGE"] || ENV["CI"]
  require "simplecov"
  SimpleCov.command_name "core"
  SimpleCov.start do
    add_filter "/test/"
    add_filter "/demo/"
    add_filter "/frontend/"
    add_group "Core", "lib/sentiero"
    add_group "Rails", "lib/sentiero/rails"
    enable_coverage :branch
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "sentiero"

# A SQLite store holds one connection per thread until #close. Open stores
# through this helper so teardown releases their file descriptors; otherwise
# the suite exhausts a 256-fd ulimit (the macOS default).
module SQLiteStoreTracking
  def open_sqlite_store(store_class = Sentiero::Stores::SQLite, **options)
    store_class.new(**options).tap { |store| (@sqlite_stores ||= []) << store }
  end

  def after_teardown
    @sqlite_stores&.each(&:close)
    super
  end
end
