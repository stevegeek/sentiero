# frozen_string_literal: true

require "test_helper"

# `require "sentiero/stores/sqlite"` must be enough on its own — the store
# file loads the sqlite3 gem itself rather than expecting the caller to have
# required it first. Runs in a subprocess so the assertion can't be satisfied
# by another test file having already loaded sqlite3 in this process.
class SQLiteRequireTest < Minitest::Test
  def test_requiring_the_store_file_loads_sqlite3
    begin
      gem "sqlite3"
    rescue Gem::LoadError
      skip "sqlite3 gem not available"
    end

    lib = ::File.expand_path("../../lib", __dir__)
    # stderr is discarded: the child inherits bundler via RUBYOPT, which is
    # noisy on some rubies. On failure the LoadError prevents "ok" printing.
    out = IO.popen(
      [RbConfig.ruby, "-I", lib, "-e",
        'require "sentiero"; require "sentiero/stores/sqlite"; Sentiero::Stores::SQLite.new(path: ":memory:"); print "ok"'],
      err: ::File::NULL, &:read
    )

    assert_equal "ok", out
  end
end
